#!/bin/bash
# Re-parse asicmon T0/T1 snapshots into a delta CSV.
# Usage: parse_asic.sh <results_dir>   (expects asic_qp<QP>_t0.txt / _t1.txt)
set -u
D="$1"
# extractors: read value of key=NUM from a specific context
val_sched0(){ grep -m1 "Sched0=" "$1" 2>/dev/null | sed -n 's/.*Sched0=\([0-9]*\).*/\1/p'; }
val_txs(){ # $1 file, $2 sched idx(0/1), $3 field(Set|Clear)
  awk -v idx="$2" -v fld="$3" '
    $0 ~ ("== TX Scheduler " idx " ==") {f=1; next}
    f {match($0, fld"=[0-9]+"); if(RSTART){v=substr($0,RSTART,RLENGTH); split(v,a,"="); print a[2]; exit}}
  ' "$1" 2>/dev/null
}
val_kv(){ grep -m1 "$2" "$1" 2>/dev/null | sed -n "s/.*$3=\([0-9]*\).*/\1/p"; }
d(){ echo $(( ${2:-0} - ${1:-0} )); }

echo "qp,bw_avg_gbps,msgrate_mpps,dSched0,dTXS0_Set,dTXS0_Clear,dTXS1_Set,dTXS1_Clear,dNPV_phv,dNPV_phvdrop,dDMA_phv2dma,dPRD_phb_drops"
for QP in 2 8 16 32; do
  t0="$D/asic_qp${QP}_t0.txt"; t1="$D/asic_qp${QP}_t1.txt"
  cli="$D/cli_qp${QP}.log"
  [ -f "$t0" ] && [ -f "$t1" ] || { echo "$QP,MISSING"; continue; }
  BW=$(grep -E "^[[:space:]]*1048576" "$cli" 2>/dev/null | awk '{print $4}' | tail -1)
  MR=$(grep -E "^[[:space:]]*1048576" "$cli" 2>/dev/null | awk '{print $5}' | tail -1)
  ds=$(d "$(val_sched0 $t0)" "$(val_sched0 $t1)")
  t0s0=$(val_txs $t0 0 Set); t1s0=$(val_txs $t1 0 Set)
  t0c0=$(val_txs $t0 0 Clear); t1c0=$(val_txs $t1 0 Clear)
  t0s1=$(val_txs $t0 1 Set); t1s1=$(val_txs $t1 1 Set)
  t0c1=$(val_txs $t0 1 Clear); t1c1=$(val_txs $t1 1 Clear)
  np0=$(val_kv $t0 "NPV:" phv); np1=$(val_kv $t1 "NPV:" phv)
  npd0=$(val_kv $t0 "NPV:" phv_drop); npd1=$(val_kv $t1 "NPV:" phv_drop)
  dm0=$(val_kv $t0 "DMA: phv_to_dma" phv_to_dma); dm1=$(val_kv $t1 "DMA: phv_to_dma" phv_to_dma)
  pb0=$(val_kv $t0 "phb_drops" phb_drops); pb1=$(val_kv $t1 "phb_drops" phb_drops)
  echo "$QP,${BW:-NA},${MR:-NA},$ds,$(d $t0s0 $t1s0),$(d $t0c0 $t1c0),$(d $t0s1 $t1s1),$(d $t0c1 $t1c1),$(d $np0 $np1),$(d $npd0 $npd1),$(d $dm0 $dm1),$(d $pb0 $pb1)"
done
