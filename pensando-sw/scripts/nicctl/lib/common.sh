#!/bin/bash
# Common utilities for nicctl monitoring scripts.
# Source this file — do not execute it directly.

set -u

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Helpers ───────────────────────────────────────────────────────────────────
die()  { echo -e "${RED}Error: $*${NC}" >&2; exit 1; }
warn() { echo -e "${YELLOW}Warning: $*${NC}" >&2; }
info() { echo -e "${CYAN}$*${NC}"; }

is_uuid() {
    [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

# ── LIF resolution ────────────────────────────────────────────────────────────
# Usage:  resolve_lif [provided_lif]
# Prints: LIF UUID to stdout.  Exits on any error.
#
# Fixes the original bug: LIF auto-parse was gated on [ -z "$QP" ] which is
# always false after argument validation, so LIF was never actually detected.
# Now auto-detection runs whenever no LIF is explicitly provided.
resolve_lif() {
    local provided="${1:-}"

    # Explicit --lif supplied: validate format then use it.
    if [[ -n "$provided" ]]; then
        is_uuid "$provided" || die "Invalid LIF UUID: '$provided'"
        echo "$provided"
        return 0
    fi

    # Auto-detect from nicctl show lif.
    local raw
    raw=$(sudo nicctl show lif 2>/dev/null) || true

    local lifs
    lifs=$(echo "$raw" \
        | grep -E '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' \
        | awk '{print $1}') || true

    [[ -n "$lifs" ]] || die "No LIF found via 'nicctl show lif'. Is the NIC up?"

    local count
    count=$(echo "$lifs" | wc -l)

    if [[ "$count" -eq 1 ]]; then
        echo "$lifs"
        return 0
    fi

    # Multiple LIFs: prompt the user (interactive terminals only).
    if [[ ! -t 0 ]]; then
        die "Multiple LIFs found but stdin is not a terminal. Use -l/--lif <uuid> to specify."
    fi

    warn "Multiple LIFs found. Use -l/--lif <uuid> to skip this prompt."
    echo "" >&2
    local i=1
    while IFS= read -r lif; do
        printf "  %d) %s\n" "$i" "$lif" >&2
        ((i++))
    done <<< "$lifs"
    echo "" >&2

    local choice
    read -rp "Select LIF [1-$count]: " choice

    [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "$count" ]] \
        || die "Invalid selection: $choice"

    echo "$lifs" | sed -n "${choice}p"
}

# ── Argument parsers ──────────────────────────────────────────────────────────
# parse_common_args: sets INTERVAL and LIF_ARG from flags common to all scripts.
# parse_qp_args: additionally sets QP from positional or --qp flag.

parse_common_args() {
    INTERVAL="${INTERVAL:-1}"
    LIF_ARG=""

    local args=("$@")
    local i=0
    while [[ $i -lt ${#args[@]} ]]; do
        case "${args[$i]}" in
            -n|--interval)
                ((i++))
                INTERVAL="${args[$i]}"
                [[ "$INTERVAL" =~ ^[0-9]+(\.[0-9]+)?$ ]] \
                    || die "--interval must be a number (got '$INTERVAL')"
                ;;
            -l|--lif)
                ((i++))
                LIF_ARG="${args[$i]}"
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            -*)
                die "Unknown argument: ${args[$i]}"
                ;;
        esac
        ((i++))
    done
}

parse_qp_args() {
    QP=""
    INTERVAL="${INTERVAL:-1}"
    LIF_ARG=""

    # Positional first argument treated as QP if it looks like a UUID or integer.
    if [[ "${1:-}" =~ ^[0-9a-fA-F-]+$ ]] && [[ "${1:-}" != -* ]]; then
        QP="$1"
        shift
    fi

    local args=("$@")
    local i=0
    while [[ $i -lt ${#args[@]} ]]; do
        case "${args[$i]}" in
            -q|--qp)
                ((i++))
                QP="${args[$i]}"
                ;;
            -n|--interval)
                ((i++))
                INTERVAL="${args[$i]}"
                [[ "$INTERVAL" =~ ^[0-9]+(\.[0-9]+)?$ ]] \
                    || die "--interval must be a number (got '$INTERVAL')"
                ;;
            -l|--lif)
                ((i++))
                LIF_ARG="${args[$i]}"
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            -*)
                die "Unknown argument: ${args[$i]}"
                ;;
        esac
        ((i++))
    done

    [[ -n "$QP" ]] || die "Queue Pair ID is required. Pass it as the first argument or with -q/--qp."
}

# ── Banner ────────────────────────────────────────────────────────────────────
print_banner() {
    local lif="$1" interval="$2" qp="${3:-}"
    echo -e "${BOLD}─────────────────────────────────────────${NC}"
    info "LIF:      $lif"
    [[ -n "$qp" ]] && info "QP:       $qp"
    info "Interval: ${interval}s"
    echo -e "${BOLD}─────────────────────────────────────────${NC}"
}
