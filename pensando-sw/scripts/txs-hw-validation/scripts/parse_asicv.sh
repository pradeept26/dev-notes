#!/bin/bash
# Parse asicmon -v (asicv_*) T0/T1 deltas: NPV phv, PSP phv, per-stage SDP PHV processed,
# and total PBUS stage drops. Cumulative counters only.
# Usage: parse_asicv.sh <results_dir>
set -u
D="$1"
npv(){ grep -m1 "NPV: phv=" "$1" 2>/dev/null | sed -n 's/.*NPV: phv=\([0-9]*\).*/\1/p'; }
psp(){ grep -m1 "PSP: phv=" "$1" 2>/dev/null | sed -n 's/.*PSP: phv=\([0-9]*\).*/\1/p'; }
sdp_sum(){ awk '/SDP: PHV processed count=/{n=$0; sub(/.*count=/,"",n); sub(/ .*/,"",n); s+=n} END{print s+0}' "$1" 2>/dev/null; }
pbus_drop(){ awk '{while(match($0,/drop=[0-9]+/)){v=substr($0,RSTART+5,RLENGTH-5); s+=v; $0=substr($0,RSTART+RLENGTH)}} END{print s+0}' "$1" 2>/dev/null; }
d(){ echo $(( ${2:-0} - ${1:-0} )); }
echo "qp,dNPV_phv,dPSP_phv,dSDP_phvproc_sum,dPBUS_drops(all-stage)"
for QP in 2 8 16 32; do
  t0="$D/asicv_qp${QP}_t0.txt"; t1="$D/asicv_qp${QP}_t1.txt"
  [ -f "$t0" ] && [ -f "$t1" ] || { echo "$QP,MISSING"; continue; }
  echo "$QP,$(d "$(npv $t0)" "$(npv $t1)"),$(d "$(psp $t0)" "$(psp $t1)"),$(d "$(sdp_sum $t0)" "$(sdp_sum $t1)"),$(d "$(pbus_drop $t0)" "$(pbus_drop $t1)")"
done
