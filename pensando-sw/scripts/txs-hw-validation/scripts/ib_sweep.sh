#!/bin/bash
# IB write_bw bidir sweep with asicmon capture. Single NIC pair (benic1p1).
# Usage: ib_sweep.sh <label> <rcn_off|rcn_on>
# Env: SSHPASS must be set (amd123)
set -u
LABEL="$1"; RCN="$2"
S1=10.30.75.198   # server (smc1)
S2=10.30.75.204   # client (smc2)
DEV=roce_benic1p1
GID=2
SRVIP=2001:db8:1::1
UUID=42424650-5232-3534-3830-303136000000   # smc1 benic1p1 card
OUT=/tmp/results/${LABEL}_${RCN}_ib
mkdir -p "$OUT"
SSH="sshpass -e ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10"
ssh1(){ $SSH ubuntu@$S1 "$@"; }
ssh2(){ $SSH ubuntu@$S2 "$@"; }

asnap(){ # $1=tag  -> capture asicmon plain+verbose scoped to card
  ssh1 "sudo asicmon --card $UUID 2>/dev/null"   > "$OUT/asic_${2}_${1}.txt" 2>&1
  ssh1 "sudo asicmon -v --card $UUID 2>/dev/null" > "$OUT/asicv_${2}_${1}.txt" 2>&1
}

echo "=== [$LABEL/$RCN] IB sweep start $(date) ===" | tee "$OUT/summary.txt"

for QP in 2 8 16 32; do
  TX=128; RX=512   # all abs_qps<=127 tier
  ssh1 "sudo killall -9 ib_write_bw 2>/dev/null"; ssh2 "sudo killall -9 ib_write_bw 2>/dev/null"; sleep 2
  COMMON="--use_hugepages -i 1 --report_gbits -p 18515 -F -q $QP -t $TX -r $RX -D 60 -b -s 1048576 --ipv6-addr"
  # T0 snapshot
  asnap t0 "qp${QP}"
  # server
  ssh1 "sudo nohup ib_write_bw -d $DEV -x $GID $COMMON > /tmp/ib_srv_${LABEL}_${RCN}_qp${QP}.log 2>&1 &"
  sleep 6
  # client (background so we can sample asicmon during the 60s)
  ssh2 "sudo nohup ib_write_bw -d $DEV -x $GID $COMMON $SRVIP > /tmp/ib_cli_${LABEL}_${RCN}_qp${QP}.log 2>&1 &"
  # live samples during run
  for s in 1 2 3; do sleep 18; asnap "live${s}" "qp${QP}"; done
  # wait for client to finish (should be ~66s total); poll up to 40 more s
  for w in $(seq 1 20); do ssh2 "pgrep -f 'ib_write_bw.*-q $QP ' >/dev/null" || break; sleep 3; done
  sleep 2
  # T1 snapshot
  asnap t1 "qp${QP}"
  # fetch client log (parsing done post-loop by parse_asic.sh)
  ssh2 "cat /tmp/ib_cli_${LABEL}_${RCN}_qp${QP}.log" > "$OUT/cli_qp${QP}.log" 2>&1
  BW=$(grep -E "^[[:space:]]*1048576" "$OUT/cli_qp${QP}.log" | awk '{print $4}' | tail -1)
  echo "  qp$QP done: BW=${BW:-NA} Gbps" | tee -a "$OUT/summary.txt"
done
/tmp/parse_asic.sh "$OUT" | tee "$OUT/ib.csv"
ssh1 "sudo killall -9 ib_write_bw 2>/dev/null"; ssh2 "sudo killall -9 ib_write_bw 2>/dev/null"
echo "=== [$LABEL/$RCN] IB sweep done $(date) ===" | tee -a "$OUT/summary.txt"
echo "--- anomalies post ---" | tee -a "$OUT/summary.txt"
ssh1 "sudo nicctl show pipeline internal rdma anomalies 2>&1 | grep -viE 'Failed to get lif|^\s*$'" | tee -a "$OUT/summary.txt"
