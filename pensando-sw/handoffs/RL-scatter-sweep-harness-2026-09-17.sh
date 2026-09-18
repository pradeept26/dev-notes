#!/bin/bash
# Paired RL on/off sweep: {PPG en/dis} x {RCN en/dis} x QP x {RL on/off}
# fw 1.130.0-a-129-30 (ToT + RL scatter). bidir 1MB, -D 20, path count 4.
set -u
C=10.30.52.66; S=10.30.52.75; BDF=0000:c1:00.0; IBWB=/usr/bin/ib_write_bw; LIF=1; DUR=20
OUT=/tmp/rlsweep; CSV=$OUT/results2.csv; mkdir -p $OUT
SP="sshpass -p docker ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10"
CPL="19.1.0.2,19.2.0.2,19.3.0.2,19.4.0.2"; SPL="19.1.0.1,19.2.0.1,19.3.0.1,19.4.0.1"
echo "config,ppg,rcn,qp,rl,bw_gbps,d_exceed,d_specfail,status" > $CSV

cfg_common() { # host ppg rcn
  $SP root@$1 "
    nicctl update pipeline rdma path -p 0 --count 4 --bdf $BDF >/dev/null 2>&1
    nicctl update pipeline rdma congestion-control profile -p 0 -r $3 -o 7 --active-path-per-path-group $2 --bdf $BDF >/dev/null 2>&1
  " >/dev/null 2>&1
}
cfg_rl() { # host onoff
  if [ "$2" = "on" ]; then
    $SP root@$1 "nicctl debug update pipeline internal rate-limit --lif $LIF --enable --rate-bps 199000000000 --burst-bytes 256000 --max-ports 4 --window-lg2 10 --bdf $BDF >/dev/null 2>&1" >/dev/null 2>&1
  else
    $SP root@$1 "nicctl debug update pipeline internal rate-limit --lif $LIF --disable --max-ports 4 --bdf $BDF >/dev/null 2>&1" >/dev/null 2>&1
  fi
}
clr() { $SP root@$1 "nicctl clear pipeline internal state --bdf $BDF >/dev/null 2>&1" >/dev/null 2>&1; }
rl_snap() { $SP root@$1 "nicctl show pipeline internal rate-limit --bdf $BDF 2>/dev/null | grep -iE 'exceed_count|rl_spec_fail' | grep -oE '[0-9]+' | head -2 | tr '\n' ' '" 2>/dev/null; }
kill_ib() { $SP root@$C 'pkill -9 ib_write_bw 2>/dev/null; true' >/dev/null 2>&1; $SP root@$S 'pkill -9 ib_write_bw 2>/dev/null; true' >/dev/null 2>&1; }

do_traffic() { # qp -> echoes BW (or empty)
  local qp=$1
  kill_ib; sleep 1
  $SP root@$S "nohup numactl --cpunodebind=netdev:enp195s0f3 $IBWB -d rocep195s0f3 --use_hugepages -m 4096 -s 1048576 -q $qp -x 1 --report_gbits --planes=$SPL -D $DUR --tclass=96 -t 32 -r 32 -b > /tmp/srv.log 2>&1 &" >/dev/null 2>&1
  local w=$((12 + qp/25)); [ $w -gt 95 ] && w=95; sleep $w
  local cl=$($SP root@$C "numactl --cpunodebind=netdev:enp195s0f3 $IBWB -d rocep195s0f3 --use_hugepages -m 4096 -s 1048576 -q $qp -x 1 --report_gbits --planes=$CPL -D $DUR --tclass=96 -t 32 -r 32 -b 10.30.52.75 2>&1")
  echo "$cl" | grep -E '1048576' | tail -1 | awk '{print $4}'
}

run_point() { # tag ppg rcn qp rl
  local tag=$1 ppg=$2 rcn=$3 qp=$4 rl=$5
  cfg_common $C $ppg $rcn; cfg_common $S $ppg $rcn
  cfg_rl $C $rl; cfg_rl $S $rl
  clr $C; clr $S
  local b4=$(rl_snap $C); local e0=$(echo $b4|awk '{print $1+0}'); local s0=$(echo $b4|awk '{print $2+0}')
  local bw=$(do_traffic $qp)
  local st="OK"
  if [ -z "$bw" ]; then   # retry once
    echo "    retry $tag qp=$qp rl=$rl"; clr $C; clr $S; bw=$(do_traffic $qp)
  fi
  [ -z "$bw" ] && { bw="NA"; st="FAIL"; }
  local af=$(rl_snap $C); local e1=$(echo $af|awk '{print $1+0}'); local s1=$(echo $af|awk '{print $2+0}')
  echo "  [$tag] qp=$qp rl=$rl -> BW=$bw dRED=$((e1-e0)) dSF=$((s1-s0)) [$st]"
  echo "$tag,$ppg,$rcn,$qp,$rl,$bw,$((e1-e0)),$((s1-s0)),$st" >> $CSV
  kill_ib; clr $C; clr $S; sleep 2
}

QPS="8 64 256 512 1024 2048"
for pr in "enable enable PPGen_RCNen" "enable disable PPGen_RCNdis" "disable enable PPGdis_RCNen" "disable disable PPGdis_RCNdis"; do
  set -- $pr; PPG=$1; RCN=$2; TAG=$3
  echo "===== CONFIG $TAG ====="
  for QP in $QPS; do
    run_point $TAG $PPG $RCN $QP on
    run_point $TAG $PPG $RCN $QP off
  done
done
echo "=== SWEEP2 DONE ==="; cat $CSV
