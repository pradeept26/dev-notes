#!/bin/bash
# watch_qp_path_status.sh — Watch per-path DCQCN congestion window for a QP.
#
# Tracks the congestion window across all paths of an RDMA Queue Pair,
# useful for diagnosing DCQCN behaviour and back-pressure during RCCL runs.
#
# Usage:
#   ./watch_qp_path_status.sh <qp_id> [OPTIONS]
#   ./watch_qp_path_status.sh -q <qp_id> [OPTIONS]
#
# Options:
#   -q, --qp <id>           Queue Pair ID (required; or pass as first arg)
#   -l, --lif <uuid>        Use a specific LIF UUID (default: auto-detect)
#   -n, --interval <sec>    Watch refresh interval in seconds (default: 1)
#   -h, --help              Show this help and exit
#
# Environment:
#   QP        Pre-set QP ID (overridden by --qp / first positional arg)
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
QP="${QP:-}"
LIF_ARG="${LIF:-}"
INTERVAL="${INTERVAL:-1}"

parse_qp_args "$@"

# ── Resolve LIF ───────────────────────────────────────────────────────────────
LIF=$(resolve_lif "$LIF_ARG")

print_banner "$LIF" "$INTERVAL" "$QP"

# ── Watch ─────────────────────────────────────────────────────────────────────
# Field: congestion window (shows DCQCN cwnd per path)
watch -n "$INTERVAL" \
    "sudo nicctl show rdma queue-pair path \
        --queue-pair-id \"$QP\" \
        --lif \"$LIF\" \
        --status \
    | grep -i 'path id\|congestion window'"
