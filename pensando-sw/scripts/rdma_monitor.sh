#!/bin/bash
# rdma_monitor.sh — Launch an RDMA monitoring tmux session for a remote AMD Pensando NIC node.
#
# Connects to a remote node, discovers the LIF UUID, then opens a 3-pane tmux
# session. Each pane auto-discovers the active RCCL QP on every refresh, so the
# monitor adapts automatically when jobs start, stop, or restart.
#
#   ┌──────────────────────────┬───────────────────────────────┐
#   │                          │  QP Status                    │
#   │  Path Stats              │  congestion / paths      ~50% │
#   │  RTT / timeout / inact   ├───────────────────────────────┤
#   │  (full height)           │  Path Cwnd                    │
#   │                          │  DCQCN congestion window ~50% │
#   └──────────────────────────┴───────────────────────────────┘
#
# Usage:
#   rdma_monitor.sh <node_ip> [interface] [OPTIONS]
#
# Examples:
#   rdma_monitor.sh 10.10.1.5                           # first LIF auto-detected
#   rdma_monitor.sh 10.10.1.5 enp8s0f0np0
#   rdma_monitor.sh 10.10.1.5 enp8s0f0np0 --user root --interval 2
#   rdma_monitor.sh 10.10.1.5 --lif <uuid>              # skip LIF discovery
#   rdma_monitor.sh 10.10.1.5 --session my-rdma --attach
#
# Options:
#   -u, --user <user>         SSH username (default: auto-detect)
#   -i, --identity <file>     SSH private key file
#   -l, --lif <uuid>          Skip LIF discovery, use this UUID
#   -n, --interval <sec>      Refresh interval in seconds (default: 1)
#   -s, --session <name>      tmux session name (default: rdma-<ip>[-<intf>])
#       --attach              Reattach to an existing session
#   -h, --help                Show this help and exit
#
# LIF Discovery (tried in order):
#   1. Match <interface> name in 'nicctl show lif' output (word-boundary match)
#   2. Match MAC address of <interface> in 'nicctl show lif' output
#   3. If exactly one LIF exists, use it with a warning
#   4. Error — use --lif to specify manually
#
# QP Discovery (per pane, every refresh):
#   Each pane independently runs:
#     nicctl show rdma queue-pair --used --rccl-data --lif <LIF> --state active
#   and takes the first result. No QP needs to be active at launch — panes
#   show a "waiting" message and start displaying data as soon as a job runs.
#
# SSH / Credentials:
#   Default credential chain (tried in order):
#     1. root / docker       (via sshpass if installed)
#     2. ubuntu / amd123     (via sshpass if installed)
#     3. root or ubuntu      (key-based / ssh-agent)
#     4. Interactive prompt  (user types username + password)
#   If -u/--user is given, that user is tried (keys, then known passwords).
#   sshpass uses the SSHPASS env var (password not visible in ps).
#
# Dependencies (local): tmux, ssh
# Dependencies (remote): nicctl, sudo, awk, grep, date

set -uo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

die()     { echo -e "${RED}[rdma_monitor] Error: $*${NC}" >&2; exit 1; }
warn()    { echo -e "${YELLOW}[rdma_monitor] Warning: $*${NC}" >&2; }
info()    { echo -e "${CYAN}[rdma_monitor] $*${NC}" >&2; }
success() { echo -e "${GREEN}[rdma_monitor] $*${NC}" >&2; }
step()    { echo -e "${BLUE}▶ $*${NC}" >&2; }

# ── Usage ─────────────────────────────────────────────────────────────────────
show_usage() {
    sed -n '/^# rdma_monitor/,/^[^#]/{ /^#/s/^# \{0,1\}//p; }' "$0"
}

# ── Argument Parsing ──────────────────────────────────────────────────────────
NODE_IP=""
INTF=""
SSH_USER=""
SSH_KEY=""
LIF_OVERRIDE=""
INTERVAL=1
SESSION_NAME=""
ATTACH_EXISTING=false
USER_EXPLICIT=false

parse_args() {
    # Handle --help/-h before touching positional args.
    for arg in "$@"; do
        [[ "$arg" == "-h" || "$arg" == "--help" ]] && { show_usage; exit 0; }
    done

    [[ $# -ge 1 ]] || { show_usage; exit 1; }

    NODE_IP="$1"; shift

    # Second positional arg is optional interface — consume if it's not a flag.
    # Use '--' to force an interface that starts with '-' (extremely unlikely).
    if [[ $# -gt 0 ]]; then
        if [[ "$1" == "--" ]]; then
            shift
            [[ $# -gt 0 ]] && { INTF="$1"; shift; }
        elif [[ "$1" != -* ]]; then
            INTF="$1"; shift
        fi
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --)            shift; break ;;
            -u|--user)     SSH_USER="$2"; USER_EXPLICIT=true; shift 2 ;;
            -i|--identity) SSH_KEY="$2";      shift 2 ;;
            -l|--lif)      LIF_OVERRIDE="$2"; shift 2 ;;
            -n|--interval)
                INTERVAL="$2"
                [[ "$INTERVAL" =~ ^[0-9]+(\.[0-9]+)?$ ]] \
                    || die "--interval must be a positive number (got '$INTERVAL')"
                # Guard against spinning the remote loop at 100% CPU.
                [[ "$(echo "$INTERVAL > 0" | bc -l 2>/dev/null || echo 1)" == "1" ]] \
                    || die "--interval must be > 0"
                shift 2 ;;
            -s|--session)  SESSION_NAME="$2"; shift 2 ;;
            --attach)      ATTACH_EXISTING=true; shift ;;
            -h|--help)     show_usage; exit 0 ;;
            *)             die "Unknown argument: $1" ;;
        esac
    done

    [[ -n "$NODE_IP" ]] || die "node_ip is required"

    if [[ -z "$SESSION_NAME" ]]; then
        local suffix="${NODE_IP}${INTF:+-${INTF}}"
        SESSION_NAME="rdma-$(echo "$suffix" | tr './' '--')"
    fi
}

# ── SSH helpers ───────────────────────────────────────────────────────────────
# Authentication strategy:
#   - Default credential chain: root/docker → ubuntu/amd123 → ask user.
#   - If -u/--user was given, that user is tried directly (keys, then prompt).
#   - Password-based login uses sshpass (SSHPASS env var, not visible in ps).
#     If sshpass is not installed, falls back to key-based, then interactive.
#   - Discovered credentials are stored in SSH_PASS and prepended to every
#     SSH call (no ControlMaster — many lab hosts disable multiplexing).

SSH_PASS=""
TMUX_CREATED=false

# Run ssh with the discovered credentials.
# If SSH_PASS is set, uses sshpass; otherwise plain ssh (keys / agent).
ssh_node() {
    local opts=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
    [[ -n "$SSH_KEY" ]] && opts+=(-i "$SSH_KEY")

    if [[ -n "$SSH_PASS" ]] && command -v sshpass >/dev/null 2>&1; then
        SSHPASS="$SSH_PASS" sshpass -e ssh "${opts[@]}" "${SSH_USER}@${NODE_IP}" "$@"
    else
        ssh "${opts[@]}" "${SSH_USER}@${NODE_IP}" "$@"
    fi
}

# Test whether a user/password combo can connect (quick, silent).
_try_connect() {
    local user="$1" pass="${2:-}"
    local opts=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=5)
    [[ -n "$SSH_KEY" ]] && opts+=(-i "$SSH_KEY")

    if [[ -n "$pass" ]] && command -v sshpass >/dev/null 2>&1; then
        SSHPASS="$pass" sshpass -e ssh "${opts[@]}" "${user}@${NODE_IP}" "true" 2>/dev/null
        return $?
    fi

    # Key-based auth — silent, fast.
    ssh "${opts[@]}" -o BatchMode=yes "${user}@${NODE_IP}" "true" 2>/dev/null
    return $?
}

discover_credentials() {
    # ── Explicit --user: try that user directly ──────────────────────────
    if [[ "$USER_EXPLICIT" == true ]]; then
        step "Connecting as ${SSH_USER}@${NODE_IP} ..."
        # Try key-based first.
        if _try_connect "$SSH_USER"; then
            SSH_PASS=""
            success "Connected as ${SSH_USER}@${NODE_IP} (key-based)"
            return 0
        fi
        # Try with common passwords.
        for pass in docker amd123; do
            if _try_connect "$SSH_USER" "$pass"; then
                SSH_PASS="$pass"
                success "Connected as ${SSH_USER}@${NODE_IP}"
                return 0
            fi
        done
        # Interactive — may prompt for password.
        die "Cannot connect to ${SSH_USER}@${NODE_IP} — check credentials"
    fi

    # ── Default credential chain ─────────────────────────────────────────
    step "Trying default credentials on ${NODE_IP} ..."

    local -a creds=("root:docker" "ubuntu:amd123")
    for cred in "${creds[@]}"; do
        local user="${cred%%:*}"
        local pass="${cred##*:}"

        if _try_connect "$user" "$pass"; then
            SSH_USER="$user"
            SSH_PASS="$pass"
            success "Connected as ${user}@${NODE_IP}"
            return 0
        fi
    done

    # Try key-based with common users.
    for user in root ubuntu; do
        if _try_connect "$user"; then
            SSH_USER="$user"
            SSH_PASS=""
            success "Connected as ${user}@${NODE_IP} (key-based)"
            return 0
        fi
    done

    # ── All defaults failed — ask the user ───────────────────────────────
    warn "Default credentials (root/docker, ubuntu/amd123) failed."
    echo "" >&2

    local input_user
    read -rp "SSH username [root]: " input_user
    SSH_USER="${input_user:-root}"

    step "Connecting as ${SSH_USER}@${NODE_IP} — may prompt for password ..."
    # This will prompt interactively (no sshpass, no BatchMode).
    local opts=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
    [[ -n "$SSH_KEY" ]] && opts+=(-i "$SSH_KEY")
    ssh "${opts[@]}" "${SSH_USER}@${NODE_IP}" "true" \
        || die "Cannot connect to ${SSH_USER}@${NODE_IP}"
    SSH_PASS=""
    success "Connected as ${SSH_USER}@${NODE_IP}"
}

# SSH command string for tmux panes (includes sshpass if password-based).
pane_ssh_prefix() {
    local parts=""
    if [[ -n "$SSH_PASS" ]] && command -v sshpass >/dev/null 2>&1; then
        parts="SSHPASS='${SSH_PASS}' sshpass -e "
    fi
    parts="${parts}ssh -t -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
    [[ -n "$SSH_KEY" ]] && parts="$parts -i '${SSH_KEY}'"
    parts="$parts ${SSH_USER}@${NODE_IP}"
    echo "$parts"
}

# ── LIF Discovery ─────────────────────────────────────────────────────────────
is_uuid() {
    [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

extract_uuids() {
    grep -oE '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
}

discover_lif() {
    local intf="${1:-}"

    local lif_output
    lif_output=$(ssh_node "sudo nicctl show lif 2>/dev/null") || true

    local all_lifs
    all_lifs=$(echo "$lif_output" | extract_uuids | sort -u) || true
    local count
    count=$(echo "$all_lifs" | grep -c '[0-9a-fA-F]' || true)

    [[ "$count" -gt 0 ]] || die "No LIFs found via 'nicctl show lif'. Is the NIC up?"

    # No interface given — return the first LIF found.
    if [[ -z "$intf" ]]; then
        local lif
        lif=$(echo "$all_lifs" | head -n1)
        [[ "$count" -gt 1 ]] && warn "Multiple LIFs found; using the first. Pass interface name or --lif to pick a specific one."
        success "LIF (auto, first found): $lif"
        echo "$lif"; return 0
    fi

    step "Discovering LIF for interface '$intf' on ${NODE_IP} ..."

    # Method 1: word-boundary match of interface name in nicctl show lif output.
    # Uses -w to avoid false-matches (e.g. 'eth0' matching inside a UUID field).
    local lif
    lif=$(echo "$lif_output" | grep -iw "$intf" | extract_uuids | head -n1) || true
    if [[ -n "$lif" ]]; then
        success "LIF matched by interface name: $lif"
        echo "$lif"; return 0
    fi

    # Method 2: MAC address correlation.
    local mac
    mac=$(ssh_node "cat /sys/class/net/$intf/address 2>/dev/null" | tr '[:upper:]' '[:lower:]') || true
    if [[ -n "$mac" ]]; then
        lif=$(echo "$lif_output" | grep -i "$mac" | extract_uuids | head -n1) || true
        if [[ -n "$lif" ]]; then
            success "LIF matched by MAC address ($mac): $lif"
            echo "$lif"; return 0
        fi
    fi

    # Method 3: exactly one LIF — use it with a warning.
    if [[ "$count" -eq 1 ]]; then
        warn "Could not match LIF to '$intf' — using the only LIF found."
        success "LIF: $all_lifs"
        echo "$all_lifs"; return 0
    fi

    warn "Multiple LIFs found and none matched '$intf'. Use --lif to specify one of:"
    echo "$all_lifs" | while IFS= read -r l; do echo "    $l"; done >&2
    die "LIF discovery failed for interface '$intf'. Use --lif <uuid>."
}

# ── Remote pane script ────────────────────────────────────────────────────────
# Pushes a single parameterized monitoring script to /tmp on the remote node.
# Each pane invokes it with a different mode + grep pattern, avoiding
# three nearly-identical copies.
#
# The tag is IP-based (not PID) so reruns overwrite cleanly.
# Previous scripts for the same node are cleaned up before pushing.

REMOTE_TAG=""
REMOTE_SCRIPT=""

push_remote_script() {
    local lif="$1"

    REMOTE_TAG="rdma_mon_${NODE_IP//\./_}"
    REMOTE_SCRIPT="/tmp/${REMOTE_TAG}_pane.sh"

    step "Pushing pane script to ${NODE_IP}:/tmp ..."

    # Clean up any previous scripts for this node.
    ssh_node "rm -f /tmp/${REMOTE_TAG}_*.sh 2>/dev/null" || true

    # Push the parameterized script (chmod 700 — no world-read).
    ssh_node "cat > ${REMOTE_SCRIPT} && chmod 700 ${REMOTE_SCRIPT}" << SCRIPT
#!/bin/bash
# Auto-generated by rdma_monitor.sh — do not edit.
# Usage: \$0 <mode> <grep_pattern>
# Modes: qp_status | path_stats | path_cwnd

LIF="${lif}"
INTERVAL=${INTERVAL}

MODE="\$1"
GREP_PATTERN="\$2"

[ -z "\$MODE" ] && { echo "Usage: \$0 <mode> <grep_pattern>"; exit 1; }

while true; do
    # Buffer output first, then clear+print in one shot (no flicker).
    OUTPUT=""
    QP=\$(sudo nicctl show rdma queue-pair --used --rccl-data --lif "\$LIF" --state active 2>/dev/null \
        | awk '\$1 ~ /^[0-9]+\$/ { print \$1; exit }')
    TS=\$(date '+%H:%M:%S')
    if [ -n "\$QP" ]; then
        HEADER=\$(printf "  LIF: %s\n  QP:  %s  |  %s\n" "\$LIF" "\$QP" "\$TS")
        DATA=\$(case "\$MODE" in
            qp_status)
                sudo nicctl show rdma queue-pair --queue-pair-id "\$QP" --lif "\$LIF" --status ;;
            path_stats)
                sudo nicctl show rdma queue-pair path --queue-pair-id "\$QP" --lif "\$LIF" statistics ;;
            path_cwnd)
                sudo nicctl show rdma queue-pair path --queue-pair-id "\$QP" --lif "\$LIF" --status ;;
        esac | grep -i "\$GREP_PATTERN" || true)
        OUTPUT="\${HEADER}\n\n\${DATA}"
    else
        OUTPUT=\$(printf "  %s — no active RCCL QP, waiting for a job to start..." "\$TS")
    fi
    clear
    echo -e "\$OUTPUT"
    sleep "\$INTERVAL"
done
SCRIPT

    success "Pane script pushed: ${REMOTE_SCRIPT}"
}

# ── tmux Layout ───────────────────────────────────────────────────────────────
build_tmux_session() {
    local lif="$1"
    local ssh_prefix
    ssh_prefix=$(pane_ssh_prefix)

    step "Creating tmux session '$SESSION_NAME' ..."

    # Create session (single window, pane 0 starts here)
    tmux new-session -d -s "$SESSION_NAME" -n "rdma-monitor"

    # Session-wide options
    tmux set-option -t "$SESSION_NAME" mouse on
    tmux set-option -t "$SESSION_NAME" pane-border-status top
    tmux set-option -t "$SESSION_NAME" pane-border-format \
        " #{?pane_active,#[bold],}#{pane_title}#[default] "
    tmux set-option -t "$SESSION_NAME" status-right \
        "#[bold]${NODE_IP}${INTF:+ | ${INTF}} | LIF: ${lif:0:8}...#[default]"

    # Layout:
    #   pane 0  — left, full height, ~50% width  (Path Stats — tall, many paths)
    #   pane 1  — top-right, ~50% height          (QP Status)
    #   pane 2  — bottom-right, ~50% height       (Path Cwnd)

    # Split right half off → pane 1; pane 0 keeps full height on the left
    tmux split-window -h -p 50 -t "$SESSION_NAME:0"

    # Split right pane (1) top/bottom → pane 2 gets bottom 50%
    tmux split-window -v -p 50 -t "$SESSION_NAME:0.1"

    # Assign pane titles
    tmux select-pane -t "$SESSION_NAME:0.0" -T "Path Stats — RTT / timeout / inactive"
    tmux select-pane -t "$SESSION_NAME:0.1" -T "QP Status  — congestion / paths"
    tmux select-pane -t "$SESSION_NAME:0.2" -T "Path Cwnd  — DCQCN congestion window"

    # Send commands: each pane SSHes in and runs the shared script with mode + pattern.
    tmux send-keys -t "$SESSION_NAME:0.0" \
        "${ssh_prefix} 'bash ${REMOTE_SCRIPT} path_stats \"path id\\|rtt\\|inactive\\|notif\\|due to timeout\"'" Enter
    tmux send-keys -t "$SESSION_NAME:0.1" \
        "${ssh_prefix} 'bash ${REMOTE_SCRIPT} qp_status \"congestion\\|path\"'" Enter
    tmux send-keys -t "$SESSION_NAME:0.2" \
        "${ssh_prefix} 'bash ${REMOTE_SCRIPT} path_cwnd \"path id\\|congestion window\"'" Enter

    # Focus the left pane
    tmux select-pane -t "$SESSION_NAME:0.0"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    parse_args "$@"

    # Reattach to existing session.
    if [[ "$ATTACH_EXISTING" == true ]]; then
        tmux has-session -t "$SESSION_NAME" 2>/dev/null \
            || die "No session named '$SESSION_NAME'. Run without --attach to create one."
        exec tmux attach -t "$SESSION_NAME"
    fi

    # Don't clobber an existing session.
    if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        warn "Session '$SESSION_NAME' already exists."
        read -rp "Attach to existing session? [Y/n]: " yn
        case "${yn,,}" in
            n|no) die "Aborted." ;;
            *) exec tmux attach -t "$SESSION_NAME" ;;
        esac
    fi

    echo "" >&2
    echo -e "${BOLD}════════════════════════════════════════════════════${NC}" >&2
    info "Node:      ${NODE_IP}"
    info "Interface: ${INTF:-<auto>}"
    info "SSH User:  ${SSH_USER:-<auto-detect>}"
    info "Interval:  ${INTERVAL}s"
    echo -e "${BOLD}════════════════════════════════════════════════════${NC}" >&2
    echo "" >&2

    command -v tmux >/dev/null || die "'tmux' is not installed locally"

    discover_credentials

    # Verify interface exists (only when explicitly given).
    if [[ -n "$INTF" ]]; then
        ssh_node "ip link show '$INTF' >/dev/null 2>&1" \
            || die "Interface '$INTF' not found on ${NODE_IP}"
    fi

    # LIF resolution
    local lif
    if [[ -n "$LIF_OVERRIDE" ]]; then
        is_uuid "$LIF_OVERRIDE" || die "Invalid LIF UUID: '$LIF_OVERRIDE'"
        lif="$LIF_OVERRIDE"
        success "Using LIF (override): $lif"
    else
        lif=$(discover_lif "$INTF")
    fi

    echo "" >&2
    echo -e "${BOLD}────────────────────────────────────────────────────${NC}" >&2
    info "LIF: $lif"
    info "QP:  discovered per-pane on each refresh"
    echo -e "${BOLD}────────────────────────────────────────────────────${NC}" >&2
    echo "" >&2

    # Push the monitoring script to the remote node.
    push_remote_script "$lif"

    # Build tmux — panes share the SSH master via ControlPath.
    build_tmux_session "$lif"
    TMUX_CREATED=true

    success "Session '$SESSION_NAME' ready."
    echo "" >&2
    echo -e "Tip: ${CYAN}Ctrl+b + arrow keys${NC} to switch panes" >&2
    echo -e "     ${CYAN}Ctrl+b z${NC} to zoom a pane" >&2
    echo -e "     ${CYAN}Ctrl+b d${NC} to detach" >&2
    echo -e "     Reattach: ${BOLD}tmux attach -t ${SESSION_NAME}${NC}" >&2
    echo -e "     Cleanup:  ${BOLD}ssh ${SSH_USER}@${NODE_IP} 'rm -f /tmp/rdma_mon_*.sh'${NC}" >&2
    echo "" >&2

    tmux attach -t "$SESSION_NAME"
}

main "$@"
