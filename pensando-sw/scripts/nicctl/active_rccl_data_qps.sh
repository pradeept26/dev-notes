#!/bin/bash
# active_rccl_data_qps.sh — Watch all active RCCL data QPs on a LIF.
#
# Standalone local utility for finding active QPs when you need to pass
# one to the other watch_qp_* scripts manually. Not used by rdma_monitor.sh
# (which auto-discovers the active QP inside each pane on every refresh).
#
# Usage:
#   ./active_rccl_data_qps.sh [OPTIONS]
#
# Options:
#   -l, --lif <uuid>        Use a specific LIF UUID (default: auto-detect)
#   -n, --interval <sec>    Watch refresh interval in seconds (default: 1)
#   -h, --help              Show this help and exit
#
# Environment:
#   LIF       Pre-set LIF UUID (overridden by --lif)
#   INTERVAL  Watch interval in seconds (overridden by --interval)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

show_usage() {
    grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \{0,1\}//'
}

# ── Parse arguments ───────────────────────────────────────────────────────────
# Honour pre-exported LIF/INTERVAL as defaults before flag parsing.
LIF_ARG="${LIF:-}"
INTERVAL="${INTERVAL:-1}"

parse_common_args "$@"

# ── Resolve LIF ───────────────────────────────────────────────────────────────
LIF=$(resolve_lif "$LIF_ARG")

print_banner "$LIF" "$INTERVAL"

# ── Watch ─────────────────────────────────────────────────────────────────────
watch -n "$INTERVAL" \
    "sudo nicctl show rdma queue-pair --used --rccl-data --lif \"$LIF\" --state active"
