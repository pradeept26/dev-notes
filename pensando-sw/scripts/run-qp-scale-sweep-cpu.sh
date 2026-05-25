#!/bin/bash
# IB CPU sweep on SMC1/SMC2 - subset matching qp-scale-sweep-report.html (CPU-only)
# Uses -a (all sizes per run) to amortize connection setup at high QP counts.
# Applies all rules from ~/dev-notes/pensando-sw/.claude/skills/run-ib/SKILL.md:
#   --use_hugepages, -i 1 (GID 1 = RoCE v2)
#   TX/RX depth tiers by QP, CQ cap (65,435)
#   --noPeak + pow2 iters at QP>=512
#   path_count auto-adjust (qp x npaths <= 8192)
#   Skip write_with_imm @ QP=4090 (KI-009)
set -u

SRV_IP=10.30.75.198
CLI_IP=10.30.75.204
NIC=roce_benic1p1
IFACE=benic1p1
PASS=amd123
BASE_PORT=18500
OUTDIR="${OUTDIR:-/home/pradeept/dev-notes/pensando-sw/scripts/ib-master-pi10-$(date +%Y%m%d_%H%M)}"
QPS="2 8 16 64 256 1024 4090"
MODES="write_bw write_with_imm"

mkdir -p "$OUTDIR"
SSH_OPTS="-o StrictHostKeyChecking=no -o PreferredAuthentications=keyboard-interactive -o ConnectTimeout=10 -o LogLevel=ERROR"

pow2_ceil() { local n=$1 p=1; while [ $p -lt $n ]; do p=$((p*2)); done; echo $p; }

txrx_for_qp() {
  local qp=$1 tx rx
  if [ $qp -le 127 ]; then tx=128; rx=512
  elif [ $qp -le 511 ]; then tx=128; rx=383
  elif [ $qp -le 784 ]; then tx=64; rx=64
  else tx=8; rx=7; fi
  local cap=$(( 65435 / qp - tx )); [ $cap -lt 1 ] && cap=1; [ $rx -gt $cap ] && rx=$cap
  echo "$tx $rx"
}

iters_for_qp() {
  local qp=$1
  if [ $qp -le 64 ]; then echo 10000
  elif [ $qp -le 256 ]; then echo 1000
  else echo 1024; fi
}

npaths_for_qp() {
  local qp=$1
  local max=$(( 8192 / qp ))
  [ $max -ge 8 ] && echo 8 || { [ $max -lt 1 ] && echo 1 || echo $max; }
}

set_path_count() {
  local np=$1
  for H in $SRV_IP $CLI_IP; do
    sshpass -p $PASS ssh $SSH_OPTS ubuntu@$H \
      "echo $PASS | sudo -S nicctl update pipeline rdma path -p 0 --count $np >/dev/null 2>&1" </dev/null
  done
}

CSV="$OUTDIR/summary.csv"
echo "mode,qp,size,iters,tx,rx,npaths,bw_avg_gbps,bw_peak_gbps,msgrate_mpps" > "$CSV"

PORT=$BASE_PORT
COUNT=0
START=$(date +%s)
PREV_NPATHS=8
TOTAL_CELLS=14  # 7 QPs x 2 modes (QP=4090 write_imm gets stub rows)

for QP in $QPS; do
  read TX RX <<< "$(txrx_for_qp $QP)"
  ITERS=$(iters_for_qp $QP)
  NPATHS=$(npaths_for_qp $QP)
  NO_PEAK=""
  if [ $QP -ge 512 ]; then
    NO_PEAK="--noPeak"
    ITERS=$(pow2_ceil $ITERS)
  fi
  if [ $NPATHS -ne $PREV_NPATHS ]; then
    echo "[$(date +%H:%M:%S)] path_count $PREV_NPATHS -> $NPATHS (for QP=$QP)"
    set_path_count $NPATHS
    PREV_NPATHS=$NPATHS
    sleep 2
  fi

  for MODE in $MODES; do
    COUNT=$((COUNT+1))
    PORT=$((PORT+1))
    VERB_FLAG=""
    [ "$MODE" = "write_with_imm" ] && VERB_FLAG="--write_with_imm"

    # KI-009: write_with_imm at QP=4090 fails on 1x800
    if [ "$MODE" = "write_with_imm" ] && [ $QP -ge 4090 ]; then
      for SZ in 2 4 8 16 32 64 128 256 512 1024 2048 4096 8192 16384 32768 65536 131072 262144 524288 1048576 2097152 4194304 8388608; do
        echo "$MODE,$QP,$SZ,$ITERS,$TX,$RX,$NPATHS,,SKIP_KI009," >> "$CSV"
      done
      echo "[$(date +%H:%M:%S)] [$COUNT/$TOTAL_CELLS] mode=$MODE qp=$QP SKIPPED (KI-009)"
      continue
    fi

    LOGFILE="$OUTDIR/${MODE}_qp${QP}.log"
    CELL_START=$(date +%s)
    echo "[$(date +%H:%M:%S)] [$COUNT/$TOTAL_CELLS] mode=$MODE qp=$QP tx=$TX rx=$RX iters=$ITERS npaths=$NPATHS port=$PORT"

    # Server (smc1)
    sshpass -p $PASS ssh $SSH_OPTS ubuntu@$SRV_IP \
      "echo $PASS | sudo -S bash -c 'nohup numactl --cpunodebind=netdev:$IFACE ib_write_bw $VERB_FLAG --use_hugepages -i 1 -d $NIC -q $QP -t $TX -r $RX -a --report_gbits -p $PORT -b -F -n $ITERS $NO_PEAK > /tmp/srv_${PORT}.log 2>&1 &'" </dev/null
    sleep 3

    # Client (smc2)
    sshpass -p $PASS ssh $SSH_OPTS ubuntu@$CLI_IP \
      "echo $PASS | sudo -S numactl --cpunodebind=netdev:$IFACE ib_write_bw $VERB_FLAG --use_hugepages -i 1 -d $NIC -q $QP -t $TX -r $RX -a --report_gbits -p $PORT -b -F -n $ITERS $NO_PEAK $SRV_IP" \
      > "$LOGFILE" 2>&1 </dev/null
    RC=$?
    CELL_TIME=$(( $(date +%s) - CELL_START ))
    sshpass -p $PASS ssh $SSH_OPTS ubuntu@$SRV_IP \
      "echo $PASS | sudo -S pkill -f \"ib_write_bw.*-p $PORT\" 2>/dev/null; true" </dev/null

    # Parse all 23 size rows. Output format: "<size> <iters> <peak> <avg> <msgrate>"
    # Use python for robust whitespace handling (perftest output has tab+space mix)
    python3 -c "
import re, sys
with open('$LOGFILE') as f: lines = f.readlines()
for L in lines:
    # Match: size iters peak avg msgrate
    m = re.match(r'\s*(\d+)\s+\d+\s+([0-9.]+)\s+([0-9.]+)\s+([0-9.]+)\s*\$', L)
    if m and int(m.group(1)) >= 2 and int(m.group(1)) <= 8388608:
        sz, peak, avg, mr = m.group(1), m.group(2), m.group(3), m.group(4)
        print(f'$MODE,$QP,{sz},$ITERS,$TX,$RX,$NPATHS,{avg},{peak},{mr}')
" >> "$CSV"

    if [ $RC -ne 0 ]; then
      echo "  ! client RC=$RC ($(grep -m1 -E 'error|Failed|Couldn' $LOGFILE 2>/dev/null | head -c 80))"
    fi
    ELAPSED=$(( $(date +%s) - START ))
    echo "  done in ${CELL_TIME}s (total elapsed ${ELAPSED}s)"
  done
done

# Restore default path count
[ $PREV_NPATHS -ne 8 ] && set_path_count 8

ELAPSED=$(( $(date +%s) - START ))
OK=$(awk -F, 'NR>1 && $8!="" && $8 != "SKIP_KI009" {ok++} END{print ok+0}' $CSV)
TOTAL=$(awk -F, 'NR>1 {t++} END{print t+0}' $CSV)
echo ""
echo "=== DONE in ${ELAPSED}s ($OK/$TOTAL data points) ==="
echo "CSV: $CSV"
