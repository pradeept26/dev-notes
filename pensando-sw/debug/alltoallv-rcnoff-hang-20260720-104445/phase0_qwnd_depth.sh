#!/bin/bash
# Phase 0 DEPTH poller (READ-ONLY). FIXED: standalone parser, temp files.
# Tracks canary QPs' window accounting + force_inactivate footprint to pin why
# qp_cwnd_whole crosses below qwnd_min.
# Usage: ./phase0_qwnd_depth.sh NODE LIF "qp1,qp2,qp3" [INTERVAL] [OUT]
set -uo pipefail
NODE="${1:?node}"; LIF="${2:?lif}"; QPS="${3:?csv qp ids}"; INTERVAL="${4:-3}"
OUT="${5:-phase0_depth_${NODE}_$(date +%Y%m%d-%H%M%S).log}"
PASS="${SSH_PASS:-docker}"
HERE="$(cd "$(dirname "$0")" && pwd)"; PARSER="$HERE/phase0_parse_depth.py"
RAW="$(mktemp /tmp/p0d_raw_XXXX)"; PST="$(mktemp /tmp/p0d_pst_XXXX)"
SSHP="sshpass -p ${PASS} ssh -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ConnectTimeout=10"
echo "depth: $NODE lif=$LIF qps=$QPS every ${INTERVAL}s -> $OUT"
echo "# ts qp W frac T R effW qmin ninact cc ndis nboot rto_oport inact_oport floor_bypassed" | tee "$OUT"
IFS=',' read -ra A <<< "$QPS"
while true; do
  TS=$(date +%H:%M:%S.%N | cut -c1-12)
  for QP in "${A[@]}"; do
    $SSHP root@$NODE "sudo nicctl show rdma queue-pair --raw --queue-pair-id $QP --lif $LIF 2>/dev/null" > "$RAW" 2>/dev/null
    $SSHP root@$NODE "sudo nicctl show rdma queue-pair path statistics --queue-pair-id $QP --lif $LIF -j 2>/dev/null" > "$PST" 2>/dev/null
    python3 "$PARSER" "$TS" "$QP" "$RAW" "$PST" >> "$OUT" 2>/dev/null
  done
  sleep "$INTERVAL"
done
