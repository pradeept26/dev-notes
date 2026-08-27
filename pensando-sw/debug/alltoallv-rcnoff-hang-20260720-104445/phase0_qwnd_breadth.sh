#!/bin/bash
# Phase 0 BREADTH poller (official build, READ-ONLY). FIXED: parser is a separate
# .py file (no pipe/heredoc stdin collision).
# Usage: ./phase0_qwnd_breadth.sh [NODE] [BDF] [INTERVAL] [OUT]
set -uo pipefail
NODE="${1:-10.30.69.98}"; BDF="${2:-0000:03:00.0}"; INTERVAL="${3:-1.5}"
OUT="${4:-phase0_breadth_${NODE}_$(date +%Y%m%d-%H%M%S).log}"
PASS="${SSH_PASS:-docker}"
HERE="$(cd "$(dirname "$0")" && pwd)"
PARSER="$HERE/phase0_parse_breadth.py"
TMP="$(mktemp /tmp/phase0_br_XXXX.json)"
SSHP="sshpass -p ${PASS} ssh -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ConnectTimeout=10"

echo "breadth: $NODE $BDF every ${INTERVAL}s -> $OUT"
echo "# ts qp W cc_state qstate active disabled inactive outstanding(MSN-CSN)" | tee "$OUT"
while true; do
  TS=$(date +%H:%M:%S.%N | cut -c1-12)
  $SSHP root@$NODE "sudo nicctl show rdma queue-pair --bdf $BDF --rccl-data --used -j 2>/dev/null" > "$TMP" 2>/dev/null
  python3 "$PARSER" "$TS" "$TMP" >> "$OUT" 2>/dev/null
  sleep "$INTERVAL"
done
