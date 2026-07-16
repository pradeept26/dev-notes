#!/bin/bash
# Spurious-PHV / phb_drops test. RESET method: asicmon -r before, -v after.
# Two workloads: saturated (ib_write_bw QP8) and draining (ib_write_lat QP1).
# Usage: SSHPASS=amd123 phb_test.sh <label>
set -u
LABEL="$1"
S1=10.30.75.198; S2=10.30.75.204
UUID=42424650-5232-3534-3830-303136000000
DEV=roce_benic1p1; GID=2; SRV=2001:db8:1::1
OUT=/tmp/results/phb_${LABEL}; mkdir -p "$OUT"
s1(){ sshpass -e ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 ubuntu@$S1 "$@"; }
s2(){ sshpass -e ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 ubuntu@$S2 "$@"; }
phb(){ grep -oE "phb_drops=[0-9]+" "$1" 2>/dev/null | cut -d= -f2 | tr '\n' ' '; }
realdrops(){ grep -oE " drops=[0-9]+" "$1" 2>/dev/null | tr -dc '0-9\n' | paste -sd' ' -; }
pktpb(){ grep -oE "pkt_to_pb=[0-9]+" "$1" 2>/dev/null | cut -d= -f2 | tr '\n' ' '; }

s1 "sudo killall -9 ib_write_bw ib_write_lat 2>/dev/null"; s2 "sudo killall -9 ib_write_bw ib_write_lat 2>/dev/null"; sleep 2
s1 "sudo nicctl show card statistics packet-buffer drop -c $UUID" > "$OUT/nicctl_drop_before.txt" 2>&1

## ---- SATURATED: ib_write_bw bidir QP8, -D 30 ----
BW="--use_hugepages -i 1 --report_gbits -p 18515 -F -q 8 -t 128 -r 512 -D 30 -b -s 1048576 --ipv6-addr"
s1 "sudo nohup ib_write_bw -d $DEV -x $GID $BW > /tmp/srv.log 2>&1 &"; sleep 6
s1 "sudo asicmon -r --card $UUID >/dev/null 2>&1"     # RESET counters
s2 "sudo nohup ib_write_bw -d $DEV -x $GID $BW $SRV > /tmp/cli.log 2>&1 &"
sleep 34
s1 "sudo asicmon -v --card $UUID" > "$OUT/sat_after.txt" 2>&1
s2 "grep -E '^[[:space:]]*1048576' /tmp/cli.log | tail -1" > "$OUT/sat_bw.txt" 2>&1
s1 "sudo killall -9 ib_write_bw 2>/dev/null"; s2 "sudo killall -9 ib_write_bw 2>/dev/null"; sleep 3

## ---- DRAINING: ib_write_lat QP1 (SQ empties every op) ----
LAT="--use_hugepages -i 1 -p 18516 -F -s 2 -n 3000000 --ipv6-addr"
s1 "sudo nohup ib_write_lat -d $DEV -x $GID $LAT > /tmp/srvl.log 2>&1 &"; sleep 6
s1 "sudo asicmon -r --card $UUID >/dev/null 2>&1"     # RESET counters
s2 "sudo nohup ib_write_lat -d $DEV -x $GID $LAT $SRV > /tmp/clil.log 2>&1 &"
for w in $(seq 1 40); do s2 "pgrep -f ib_write_lat >/dev/null 2>&1" || break; sleep 3; done
s1 "sudo asicmon -v --card $UUID" > "$OUT/drain_after.txt" 2>&1
s2 "cat /tmp/clil.log" > "$OUT/drain_lat.txt" 2>&1
s1 "sudo killall -9 ib_write_lat 2>/dev/null"; s2 "sudo killall -9 ib_write_lat 2>/dev/null"

s1 "sudo nicctl show card statistics packet-buffer drop -c $UUID" > "$OUT/nicctl_drop_after.txt" 2>&1

echo "===================== $LABEL ====================="
echo "[SATURATED ib_write_bw QP8 30s]  BW: $(cat $OUT/sat_bw.txt 2>/dev/null | awk '{print $4}') Gb/s"
echo "  phb_drops per PRD engine : $(phb $OUT/sat_after.txt)"
echo "  pkt_to_pb per PRD engine : $(pktpb $OUT/sat_after.txt)"
echo "  real drops=              : $(realdrops $OUT/sat_after.txt)"
echo "[DRAINING ib_write_lat QP1 3M ops]"
echo "  latency: $(grep -iE 't_avg|typical|percentile|[0-9]+\.[0-9]+ +[0-9]+\.[0-9]+' $OUT/drain_lat.txt 2>/dev/null | tail -1)"
echo "  phb_drops per PRD engine : $(phb $OUT/drain_after.txt)"
echo "  pkt_to_pb per PRD engine : $(pktpb $OUT/drain_after.txt)"
echo "  real drops=              : $(realdrops $OUT/drain_after.txt)"
echo "  nicctl PB drops (after, nonzero lines):"
grep -vE "^NIC|^Port|^-|^Reason|^$" "$OUT/nicctl_drop_after.txt" 2>/dev/null | head -20
echo "=================================================="
