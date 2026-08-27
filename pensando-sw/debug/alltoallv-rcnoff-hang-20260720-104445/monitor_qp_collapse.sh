#!/bin/bash
# Monitor Meta RoCE per-QP window/path collapse during an RCCL run.
# READ-ONLY. Samples data QPs on a NIC every INTERVAL sec and logs the
# collapse curve (how many QPs lose active paths / hit cwnd=0 / stall MSN).
#
# Usage:
#   ./monitor_qp_collapse.sh [NODE] [BDF] [INTERVAL] [OUTFILE]
# Defaults: NODE=10.30.69.98 (GT-4)  BDF=0000:03:00.0  INTERVAL=10
#
# Run one per node (GT-1 and GT-4) in separate terminals to watch both sides.

set -uo pipefail
NODE="${1:-10.30.69.98}"
BDF="${2:-0000:03:00.0}"
INTERVAL="${3:-10}"
OUT="${4:-qpcollapse_${NODE}_$(date +%Y%m%d-%H%M%S).log}"
PASS="${SSH_PASS:-docker}"

SSHP="sshpass -p ${PASS} ssh -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ConnectTimeout=10"

echo "monitoring $NODE bdf $BDF every ${INTERVAL}s -> $OUT (Ctrl-C to stop)"
echo "# ts total active0 disabled_gt0 cwnd0 outstanding min_cwnd mean_cwnd" | tee "$OUT"

while true; do
  TSNOW=$(date +%H:%M:%S)
  JSON=$($SSHP root@$NODE "sudo nicctl show rdma queue-pair --bdf $BDF --rccl-data --used -j 2>/dev/null")
  echo "$JSON" | python3 - "$TSNOW" <<'PYEOF' | tee -a "$OUT"
import sys, json
ts=sys.argv[1]
raw=sys.stdin.read()
# tolerate concatenated JSON objects (one per card) or trailing noise
import json as _j
dec=_j.JSONDecoder(); objs=[]; i=0; raw=raw.strip()
while i < len(raw):
    s=raw[i:].lstrip()
    if not s: break
    i=len(raw)-len(s)
    try:
        o,e=dec.raw_decode(raw[i:]); objs.append(o); i+=e
    except Exception:
        break
tot=act0=dis=cw0=outs=0; cwnds=[]
for o in objs:
    for nic in o.get('nic',[]):
        for lif in nic.get('lif',[]):
            for qp in lif.get('queue_pair',[]):
                tx=qp['status']['send_queue'].get('requester_tx_status',{})
                if not tx: continue
                tot+=1
                a=int(tx.get('num_active_path',0)); d=int(tx.get('num_disabled_path',0))
                cw=int(tx.get('qp_cwnd_whole',0))
                m=int(tx.get('message_sequence_number',0)); c=int(tx.get('completion_sequence_number',0))
                cwnds.append(cw)
                if a==0: act0+=1
                if d>0: dis+=1
                if cw==0: cw0+=1
                if m>c: outs+=1
mn=min(cwnds) if cwnds else 0
me=(sum(cwnds)/len(cwnds)) if cwnds else 0
print(f"{ts} {tot:>4} {act0:>7} {dis:>11} {cw0:>5} {outs:>11} {mn:>7} {me:>8.1f}")
PYEOF
  sleep "$INTERVAL"
done
