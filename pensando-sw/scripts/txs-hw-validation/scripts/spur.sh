#!/bin/bash
# One spurious-PHV run (reset method). Server=SMC1, client=SMC2, asicmon scoped to SMC1 card.
# args: LABEL DEV S1UUID S2UUID SRV_IPV6 MODE(bw|lat) QP SIZE RCN(off|on)
set -u
LABEL="$1"; DEV="$2"; S1U="$3"; S2U="$4"; SRV="$5"; MODE="$6"; QP="$7"; SIZE="$8"; RCN="$9"; TX="${10:-128}"
S1=10.30.75.198; S2=10.30.75.204; GID=2; PORT=18515
OUT=/tmp/results2/${LABEL}; mkdir -p "$OUT"; CSV=/tmp/results2/spurious.csv
s1(){ sshpass -e ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 ubuntu@$S1 "$@"; }
s2(){ sshpass -e ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 ubuntu@$S2 "$@"; }
# set RCN on this card, both hosts
rc=disable; [ "$RCN" = on ] && rc=enable
s1 "sudo nicctl update pipeline rdma congestion-control profile -p 0 --rcn $rc -c $S1U >/dev/null 2>&1"
s2 "sudo nicctl update pipeline rdma congestion-control profile -p 0 --rcn $rc -c $S2U >/dev/null 2>&1"
s1 "sudo killall -9 ib_write_bw ib_write_lat 2>/dev/null"; s2 "sudo killall -9 ib_write_bw ib_write_lat 2>/dev/null"; sleep 2
if [ "$MODE" = bw ]; then
  CMD="ib_write_bw -d $DEV -x $GID --use_hugepages -i 1 --report_gbits -p $PORT -F -q $QP -t $TX -r 512 -D 30 -b -s $SIZE --ipv6-addr"
else
  CMD="ib_write_lat -d $DEV -x $GID --use_hugepages -i 1 -p $PORT -F -s $SIZE -n 3000000 --ipv6-addr"
fi
s1 "sudo nohup $CMD > /tmp/srv.log 2>&1 &"; sleep 6
s1 "sudo asicmon -r --card $S1U >/dev/null 2>&1"        # RESET counters
s2 "sudo nohup $CMD $SRV > /tmp/cli.log 2>&1 &"
if [ "$MODE" = bw ]; then sleep 34; else for w in $(seq 1 40); do s2 "pgrep -f ib_write_lat >/dev/null 2>&1" || break; sleep 3; done; fi
s1 "sudo asicmon -v --card $S1U" > "$OUT/after.txt" 2>&1
s2 "cat /tmp/cli.log" > "$OUT/cli.log" 2>&1
s1 "sudo killall -9 ib_write_bw ib_write_lat 2>/dev/null"; s2 "sudo killall -9 ib_write_bw ib_write_lat 2>/dev/null"
# parse (cumulative-since-reset)
npv=$(grep -oE "NPV: phv=[0-9]+" "$OUT/after.txt" | cut -d= -f2 | sort -rn | head -1)
psp=$(grep -oE "PSP: phv=[0-9]+" "$OUT/after.txt" | cut -d= -f2 | sort -rn | head -1)
phb=$(grep -oE "phb_drops=[0-9]+" "$OUT/after.txt" | cut -d= -f2 | sort -rn | head -1)
sched0=$(grep -m1 -oE "Sched0=[0-9]+" "$OUT/after.txt" | cut -d= -f2)
clr=$(awk '/== TX Scheduler 0 ==/{getline; match($0,/Clear=[0-9]+/); if(RSTART)print substr($0,RSTART+6,RLENGTH-6); exit}' "$OUT/after.txt")
realdrop=$(grep -oE " drops=[0-9]+" "$OUT/after.txt" | grep -oE "[0-9]+" | sort -rn | head -1)
spur=$(( ${npv:-0} - ${psp:-0} ))
if [ "$MODE" = bw ]; then metric=$(grep -E "^[[:space:]]*$SIZE[[:space:]]" "$OUT/cli.log" | awk '{print $4}' | tail -1)
else metric=$(grep -E "^[[:space:]]*$SIZE[[:space:]]" "$OUT/cli.log" | awk '{print $6}' | tail -1); fi
echo "$LABEL,$MODE,$QP,$SIZE,$RCN,${phb:-NA},${npv:-NA},${psp:-NA},$spur,${sched0:-NA},${clr:-NA},${realdrop:-0},${metric:-NA}" | tee -a "$CSV"
