#!/bin/bash
# watch_qp_path_stats.sh — Watch per-path statistics for an RDMA Queue Pair.
#
# Displays path ID, RTT, retransmit timeouts, inactive counts, and
# notification events — useful for diagnosing path-level RDMA failures.
#
# Usage:
#   ./watch_qp_path_stats.sh <qp_id> [OPTIONS]
#   ./watch_qp_path_stats.sh -q <qp_id> [OPTIONS]
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
# Honour pre-exported env vars as defaults before flag parsing.
QP="${QP:-}"
LIF_ARG="${LIF:-}"
INTERVAL="${INTERVAL:-1}"

parse_qp_args "$@"

# ── Resolve LIF ───────────────────────────────────────────────────────────────
LIF=$(resolve_lif "$LIF_ARG")

print_banner "$LIF" "$INTERVAL" "$QP"

# ── Watch ─────────────────────────────────────────────────────────────────────
# Fields: Path id | RTT | inactive | notifications | due to timeout
watch -n "$INTERVAL" \
    "sudo nicctl show rdma queue-pair path \
        --queue-pair-id \"$QP\" \
        --lif \"$LIF\" \
        statistics \
    | grep -i 'path id\|rtt\|inactive\|notif\|due to timeout'"
