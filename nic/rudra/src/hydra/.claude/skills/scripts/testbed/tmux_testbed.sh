#!/bin/bash
#
# tmux_testbed.sh - Launch tmux session for managing testbed nodes
#
# This script creates a tmux session with:
#   - Window 1 (ssh): Split panes with SSH connections to each node
#   - Window 2 (ssh2): Optional second SSH window (requires -d flag)
#   - BMC window: Split panes with SSH connections to BMC (requires -b flag)
#   - Console windows: Windows with telnet connections to consoles (requires -c flag)
#   - SUC console windows: Windows with telnet connections to SUC consoles (requires -u flag)
#

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARSER_SCRIPT="$SCRIPT_DIR/parse_testbed.py"

# Default options
SESSION_NAME=""
CREATE_CONSOLE=false
CREATE_SUC=false
CREATE_BMC=false
DUAL_SSH=false
SYNC_PANES=false
ATTACH_EXISTING=false
ADD_TO_SESSION=""
CLEAR_LINES=false
TESTBED_FILE=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

function print_error() {
    echo -e "${RED}Error: $1${NC}" >&2
}

function print_success() {
    echo -e "${GREEN}$1${NC}"
}

function print_warning() {
    echo -e "${YELLOW}Warning: $1${NC}"
}

function usage() {
    cat << EOF
Usage: $(basename "$0") <testbed_yaml_file> [options]

Launch a tmux session for managing testbed nodes with SSH connections.

Arguments:
  testbed_yaml_file         Path to testbed YAML configuration file

Options:
  -s, --session-name NAME   Override default session name
  -d, --dual-ssh            Create two SSH windows (useful for running different commands)
  -b, --bmc                 Create BMC window with SSH connections to BMC IPs
  -c, --console             Create console windows with telnet connections (up to 8 per window)
  -u, --suc                 Create SUC console windows with telnet connections
  -y, --sync-panes          Enable synchronize-panes mode
  -a, --attach              Attach to existing session if exists
  -A, --add-to SESSION      Add windows to an existing tmux session
  -C, --clear-lines         Clear console lines before connecting (sends "clear line xx")
                            Requires CONSOLE_PASSWORD env var to be exported.
  -h, --help                Show this help message

Examples:
  # Launch tmux session with SSH connections only
  $(basename "$0") /vol/systest/hydra/testbeds/smc12.yml

  # Launch with dual SSH windows
  $(basename "$0") /vol/systest/hydra/testbeds/smc12.yml -d

  # Launch with console windows
  $(basename "$0") /vol/systest/hydra/testbeds/smc12.yml -c

  # Launch with SUC console windows
  $(basename "$0") /vol/systest/hydra/testbeds/smc12.yml -u

  # Launch with BMC SSH connections
  $(basename "$0") /vol/systest/hydra/testbeds/kenya-perf-34.yml -b

  # Launch with all console types and clear lines first
  $(basename "$0") /vol/systest/hydra/testbeds/smc12.yml -c -u -C

  # Add console windows to existing session
  $(basename "$0") /vol/systest/hydra/testbeds/smc12.yml -c -A my-session

  # Launch with synchronized panes
  $(basename "$0") /vol/systest/hydra/testbeds/smc12.yml --sync-panes

Tmux Session Navigation:
  Ctrl-b n/p        Switch between windows
  Ctrl-b arrow      Switch between panes
  Ctrl-b d          Detach from session
  Ctrl-b :          Command mode

To reattach later:
  tmux attach -t <session-name>

EOF
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            ;;
        -s|--session-name)
            SESSION_NAME="$2"
            shift 2
            ;;
        -d|--dual-ssh)
            DUAL_SSH=true
            shift
            ;;
        -c|--console)
            CREATE_CONSOLE=true
            shift
            ;;
        -u|--suc)
            CREATE_SUC=true
            shift
            ;;
        -b|--bmc)
            CREATE_BMC=true
            shift
            ;;
        -y|--sync-panes)
            SYNC_PANES=true
            shift
            ;;
        -a|--attach)
            ATTACH_EXISTING=true
            shift
            ;;
        -A|--add-to)
            ADD_TO_SESSION="$2"
            shift 2
            ;;
        -C|--clear-lines)
            CLEAR_LINES=true
            shift
            ;;
        -*)
            print_error "Unknown option: $1"
            usage
            ;;
        *)
            if [[ -z "$TESTBED_FILE" ]]; then
                TESTBED_FILE="$1"
            else
                print_error "Multiple testbed files specified"
                usage
            fi
            shift
            ;;
    esac
done

# Validate required arguments
if [[ -z "$TESTBED_FILE" ]]; then
    print_error "Missing testbed YAML file"
    usage
fi

# Check dependencies
if ! command -v tmux &> /dev/null; then
    print_error "tmux is not installed. Install with: sudo apt-get install tmux"
    exit 1
fi

if ! command -v python3 &> /dev/null; then
    print_error "python3 is not installed"
    exit 1
fi

if [[ ! -f "$PARSER_SCRIPT" ]]; then
    print_error "Parser script not found: $PARSER_SCRIPT"
    exit 1
fi

# Validate testbed file exists
if [[ ! -f "$TESTBED_FILE" ]]; then
    print_error "Testbed file not found: $TESTBED_FILE"
    exit 1
fi

# Parse testbed YAML
echo "Parsing testbed configuration..."
TESTBED_JSON=$(python3 "$PARSER_SCRIPT" "$TESTBED_FILE")
if [[ $? -ne 0 ]]; then
    print_error "Failed to parse testbed YAML"
    exit 1
fi

# Extract testbed info
TESTBED_NAME=$(echo "$TESTBED_JSON" | python3 -c "import sys, json; print(json.load(sys.stdin)['name'])")
NODE_COUNT=$(echo "$TESTBED_JSON" | python3 -c "import sys, json; print(len(json.load(sys.stdin)['nodes']))")

# Use provided session name or default to testbed name
if [[ -z "$SESSION_NAME" ]]; then
    SESSION_NAME="$TESTBED_NAME"
fi

echo "Testbed: $TESTBED_NAME"
echo "Nodes: $NODE_COUNT"
echo "Session: $SESSION_NAME"

# Function to get node info by index
function get_node_field() {
    local idx=$1
    local field=$2
    echo "$TESTBED_JSON" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data['nodes'][$idx]['$field'])"
}

# Function to get console list for a node
function get_console_list() {
    local idx=$1
    local field=$2
    echo "$TESTBED_JSON" | python3 -c "import sys, json; data=json.load(sys.stdin); consoles=data['nodes'][$idx].get('$field', []); print('\n'.join(consoles) if consoles else '')"
}

# Function to get all consoles of a type across all nodes
function get_all_consoles() {
    local field=$1
    echo "$TESTBED_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
consoles = []
for node in data['nodes']:
    node_consoles = node.get('$field', [])
    for c in node_consoles:
        consoles.append(c)
print('\n'.join(consoles))
"
}

# Function to build SSH command
function build_ssh_command() {
    local ip=$1
    local username=$2
    local password=$3

    # Common SSH options
    local ssh_opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

    if [[ -n "$password" ]]; then
        # Use sshpass if password is provided
        if ! command -v sshpass &> /dev/null; then
            print_warning "sshpass not installed, but password specified for $ip. Falling back to regular SSH."
            echo "ssh $ssh_opts ${username}@${ip}"
        else
            echo "sshpass -p '$password' ssh $ssh_opts ${username}@${ip}"
        fi
    else
        # Regular SSH (assumes key-based auth)
        echo "ssh $ssh_opts ${username}@${ip}"
    fi
}

# Function to clear a console line
function clear_console_line() {
    local console=$1
    local console_host="${console%:*}"
    local console_port="${console##*:}"
    # Get last 2 digits of port
    local line_num="${console_port: -2}"
    # Remove leading zero if present
    line_num=$((10#$line_num))

    if [[ -z "${CONSOLE_PASSWORD:-}" ]]; then
        echo -e "${YELLOW}SKIPPED (CONSOLE_PASSWORD not set)${NC} for line $line_num on $console_host"
        return 0
    fi

    echo -n "Clearing line $line_num on $console_host... "

    # Use a subshell with proper timing to handle both password and no-password cases
    # Send empty line first to trigger any login prompt, then password from
    # $CONSOLE_PASSWORD, then commands.
    local output
    output=$(
        (
            sleep 1
            echo ""                    # Trigger login prompt
            sleep 1
            echo "$CONSOLE_PASSWORD"   # Password (from env var; required for -C)
            sleep 0.5
            echo "clear line $line_num"
            sleep 0.3
            echo "y"
            sleep 0.3
            echo "exit"
        ) | timeout 8 telnet "$console_host" 23 2>&1
    ) || true  # Don't fail on timeout or telnet errors

    # Check if clear was successful by looking for [OK] in output
    if echo "$output" | grep -q "\[OK\]"; then
        echo -e "${GREEN}OK${NC}"
    elif echo "$output" | grep -q "Password:.*Password:.*Password:"; then
        echo -e "${RED}FAILED (auth failed)${NC}"
    else
        echo -e "${YELLOW}DONE${NC}"
    fi
}

# Function to create SSH panes in a window
# Layout: First split vertically (rows), then horizontally (columns)
function create_ssh_panes() {
    local window_index=$1
    local window_name=$2
    local pane_count=$NODE_COUNT

    echo "Creating SSH panes in window '$window_name'..."

    # Limit to 8 panes per window
    [[ $pane_count -gt 8 ]] && pane_count=8

    # Determine grid layout: rows x cols
    # For SSH panes, prefer vertical stacking (more rows than columns)
    local rows=1
    local cols=1
    case $pane_count in
        1) rows=1; cols=1 ;;
        2) rows=2; cols=1 ;;  # 2 rows, 1 column (stacked vertically)
        3|4) rows=2; cols=2 ;;  # 2 rows, 2 columns
        5|6) rows=3; cols=2 ;;  # 3 rows, 2 columns
        7|8) rows=4; cols=2 ;;  # 4 rows, 2 columns
    esac

    # Create panes: for SSH we prefer vertical stacking (top/bottom)
    # tmux split-window -v = vertical split (top/bottom panes)
    # tmux split-window -h = horizontal split (side by side panes)

    if [[ $pane_count -eq 2 ]]; then
        # Simple case: just one horizontal split for 2 panes side by side
        tmux split-window -h -t "$SESSION_NAME:$window_index"
    elif [[ $rows -gt 1 ]]; then
        # Step 1: Create vertical splits to make rows
        for ((r=1; r<rows; r++)); do
            local first_pane=$(tmux list-panes -t "$SESSION_NAME:$window_index" -F "#{pane_id}" | head -n1)
            tmux split-window -v -t "$first_pane"
        done
        tmux select-layout -t "$SESSION_NAME:$window_index" even-vertical

        # Step 2: Create horizontal splits within each row to make columns
        if [[ $cols -gt 1 ]]; then
            local row_panes=()
            while IFS= read -r pane; do
                row_panes+=("$pane")
            done < <(tmux list-panes -t "$SESSION_NAME:$window_index" -F "#{pane_id}")

            for row_pane in "${row_panes[@]}"; do
                for ((c=1; c<cols; c++)); do
                    tmux split-window -h -t "$row_pane"
                done
            done
            tmux select-layout -t "$SESSION_NAME:$window_index" tiled
        fi
    elif [[ $cols -gt 1 ]]; then
        # Single row with multiple columns (shouldn't happen with new layout, but keep for safety)
        for ((c=1; c<cols; c++)); do
            tmux split-window -h -t "$SESSION_NAME:$window_index"
        done
        tmux select-layout -t "$SESSION_NAME:$window_index" even-horizontal
    fi

    # Step 3: Send SSH commands to each pane
    local pane_list=()
    while IFS= read -r pane; do
        pane_list+=("$pane")
    done < <(tmux list-panes -t "$SESSION_NAME:$window_index" -F "#{pane_id}")

    for ((i=0; i<pane_count && i<${#pane_list[@]}; i++)); do
        NODE_NAME=$(get_node_field $i "name")
        NODE_IP=$(get_node_field $i "ip")
        NODE_USER=$(get_node_field $i "username")
        NODE_PASS=$(get_node_field $i "password")

        SSH_CMD=$(build_ssh_command "$NODE_IP" "$NODE_USER" "$NODE_PASS")
        tmux send-keys -t "${pane_list[$i]}" "$SSH_CMD" C-m
    done

    echo "  Created $pane_count panes (${rows}x${cols} grid)"

    # Enable sync-panes if requested
    if [[ "$SYNC_PANES" == true ]]; then
        tmux setw -t "$SESSION_NAME:$window_index" synchronize-panes on
        print_success "Synchronize-panes enabled for window '$window_name'"
    fi
}

# Function to create BMC SSH panes in a window
function create_bmc_panes() {
    local window_index=$1
    local window_name=$2

    # Count nodes with BMC IPs
    local bmc_count=0
    for ((i=0; i<NODE_COUNT; i++)); do
        local bmc_ip=$(get_node_field $i "bmc_ip" 2>/dev/null || echo "")
        [[ -n "$bmc_ip" && "$bmc_ip" != "None" ]] && ((bmc_count++))
    done

    if [[ $bmc_count -eq 0 ]]; then
        print_warning "No BMC IPs found in testbed YAML"
        return 1
    fi

    echo "Creating BMC SSH panes in window '$window_name'..."

    local pane_count=$bmc_count
    # Limit to 8 panes per window
    [[ $pane_count -gt 8 ]] && pane_count=8

    # Determine grid layout: rows x cols
    local rows=1
    local cols=1
    case $pane_count in
        1) rows=1; cols=1 ;;
        2) rows=2; cols=1 ;;
        3|4) rows=2; cols=2 ;;
        5|6) rows=3; cols=2 ;;
        7|8) rows=4; cols=2 ;;
    esac

    # Create panes
    if [[ $pane_count -eq 2 ]]; then
        tmux split-window -h -t "$SESSION_NAME:$window_index"
    elif [[ $rows -gt 1 ]]; then
        for ((r=1; r<rows; r++)); do
            local first_pane=$(tmux list-panes -t "$SESSION_NAME:$window_index" -F "#{pane_id}" | head -n1)
            tmux split-window -v -t "$first_pane"
        done
        tmux select-layout -t "$SESSION_NAME:$window_index" even-vertical

        if [[ $cols -gt 1 ]]; then
            local row_panes=()
            while IFS= read -r pane; do
                row_panes+=("$pane")
            done < <(tmux list-panes -t "$SESSION_NAME:$window_index" -F "#{pane_id}")

            for row_pane in "${row_panes[@]}"; do
                for ((c=1; c<cols; c++)); do
                    tmux split-window -h -t "$row_pane"
                done
            done
            tmux select-layout -t "$SESSION_NAME:$window_index" tiled
        fi
    elif [[ $cols -gt 1 ]]; then
        for ((c=1; c<cols; c++)); do
            tmux split-window -h -t "$SESSION_NAME:$window_index"
        done
        tmux select-layout -t "$SESSION_NAME:$window_index" even-horizontal
    fi

    # Send SSH commands to each pane
    local pane_list=()
    while IFS= read -r pane; do
        pane_list+=("$pane")
    done < <(tmux list-panes -t "$SESSION_NAME:$window_index" -F "#{pane_id}")

    local pane_idx=0
    for ((i=0; i<NODE_COUNT && pane_idx<pane_count; i++)); do
        local BMC_IP=$(get_node_field $i "bmc_ip" 2>/dev/null || echo "")
        [[ -z "$BMC_IP" || "$BMC_IP" == "None" ]] && continue

        local BMC_USER=$(get_node_field $i "bmc_username" 2>/dev/null || echo "admin")
        local BMC_PASS=$(get_node_field $i "bmc_password" 2>/dev/null || echo "")

        local SSH_CMD=$(build_ssh_command "$BMC_IP" "$BMC_USER" "$BMC_PASS")
        tmux send-keys -t "${pane_list[$pane_idx]}" "$SSH_CMD" C-m
        ((pane_idx++))
    done

    echo "  Created $pane_count BMC panes (${rows}x${cols} grid)"
}

# Function to create console panes in a window (up to 8 panes per window)
# Layout: First split vertically (rows), then horizontally (columns)
# This ensures all panes are the same size
function create_console_window() {
    local window_name=$1
    shift
    local consoles=("$@")
    local console_count=${#consoles[@]}

    if [[ $console_count -eq 0 ]]; then
        return
    fi

    # Limit to 8 panes
    [[ $console_count -gt 8 ]] && console_count=8

    echo "Creating window '$window_name' with $console_count console panes..."

    # Create the window
    tmux new-window -t "$SESSION_NAME" -n "$window_name"
    local window_index=$(tmux list-windows -t "$SESSION_NAME" -F "#{window_index}:#{window_name}" | grep ":$window_name$" | cut -d: -f1)

    # Clear lines first if requested (do this before creating panes)
    if [[ "$CLEAR_LINES" == true ]]; then
        for ((i=0; i<console_count; i++)); do
            clear_console_line "${consoles[$i]}"
        done
    fi

    # Determine grid layout: rows x cols
    # For equal-sized panes, we want a balanced grid
    local rows=1
    local cols=1
    case $console_count in
        1) rows=1; cols=1 ;;
        2) rows=1; cols=2 ;;  # 1 row, 2 columns (side by side)
        3|4) rows=2; cols=2 ;;  # 2 rows, 2 columns
        5|6) rows=2; cols=3 ;;  # 2 rows, 3 columns
        7|8) rows=2; cols=4 ;;  # 2 rows, 4 columns
    esac

    # For 2-row layouts, create columns first then split each vertically
    # This produces a cleaner grid (e.g., 2x4 for 8 panes)
    if [[ $rows -eq 2 ]]; then
        # Step 1: Create horizontal splits to make columns
        if [[ $cols -gt 1 ]]; then
            for ((c=1; c<cols; c++)); do
                tmux split-window -h -t "$SESSION_NAME:$window_index"
            done
            tmux select-layout -t "$SESSION_NAME:$window_index" even-horizontal
        fi

        # Step 2: Split each column vertically to create 2 rows
        local col_panes=()
        while IFS= read -r pane; do
            col_panes+=("$pane")
        done < <(tmux list-panes -t "$SESSION_NAME:$window_index" -F "#{pane_id}")

        for col_pane in "${col_panes[@]}"; do
            tmux split-window -v -t "$col_pane"
        done
        # No layout applied - the natural split structure gives us the 2xN grid
    else
        # Single row layout - just create horizontal splits
        if [[ $cols -gt 1 ]]; then
            for ((c=1; c<cols; c++)); do
                tmux split-window -h -t "$SESSION_NAME:$window_index"
            done
            tmux select-layout -t "$SESSION_NAME:$window_index" even-horizontal
        fi
    fi

    # Step 3: Send telnet commands to each pane
    local pane_list=()
    while IFS= read -r pane; do
        pane_list+=("$pane")
    done < <(tmux list-panes -t "$SESSION_NAME:$window_index" -F "#{pane_id}")

    for ((i=0; i<console_count && i<${#pane_list[@]}; i++)); do
        local console="${consoles[$i]}"
        local console_host="${console%:*}"
        local console_port="${console##*:}"
        local telnet_cmd="telnet $console_host $console_port"
        tmux send-keys -t "${pane_list[$i]}" "$telnet_cmd" C-m
    done

    echo "  Created $console_count panes in window '$window_name' (${rows}x${cols} grid)"
}

# Function to create multiple console windows (8 consoles per window)
function create_console_windows() {
    local window_prefix=$1
    local field=$2

    # Collect all consoles
    local all_consoles=()
    while IFS= read -r console; do
        [[ -n "$console" ]] && all_consoles+=("$console")
    done < <(get_all_consoles "$field")

    local total=${#all_consoles[@]}
    if [[ $total -eq 0 ]]; then
        print_warning "No $field consoles found in testbed YAML"
        return
    fi

    echo "Found $total $field consoles"

    # Create windows with up to 8 consoles each
    local window_num=1
    local start=0
    while [[ $start -lt $total ]]; do
        local end=$((start + 8))
        [[ $end -gt $total ]] && end=$total

        local window_consoles=("${all_consoles[@]:$start:$((end - start))}")
        local window_name="${window_prefix}${window_num}"

        create_console_window "$window_name" "${window_consoles[@]}"

        start=$end
        window_num=$((window_num + 1))
    done
}

# Check if adding to existing session
if [[ -n "$ADD_TO_SESSION" ]]; then
    if ! tmux has-session -t "$ADD_TO_SESSION" 2>/dev/null; then
        print_error "Session '$ADD_TO_SESSION' does not exist"
        exit 1
    fi
    SESSION_NAME="$ADD_TO_SESSION"
    echo "Adding windows to existing session: $SESSION_NAME"

    # Create BMC window if requested
    if [[ "$CREATE_BMC" == true ]]; then
        tmux new-window -t "$SESSION_NAME" -n "bmc"
        BMC_WINDOW=$(tmux list-windows -t "$SESSION_NAME" -F "#{window_index}:#{window_name}" | grep ":bmc$" | cut -d: -f1)
        create_bmc_panes "$BMC_WINDOW" "bmc"
    fi

    # Create console windows if requested
    if [[ "$CREATE_CONSOLE" == true ]]; then
        create_console_windows "console" "console"
    fi

    # Create SUC console windows if requested
    if [[ "$CREATE_SUC" == true ]]; then
        create_console_windows "suc" "suc"
    fi

    print_success "Windows added to session '$SESSION_NAME'"
    exit 0
fi

# Check if session already exists
if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    if [[ "$ATTACH_EXISTING" == true ]]; then
        print_success "Attaching to existing session: $SESSION_NAME"
        tmux attach -t "$SESSION_NAME"
        exit 0
    else
        print_warning "Session '$SESSION_NAME' already exists"
        read -p "Attach to existing session? (y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            tmux attach -t "$SESSION_NAME"
            exit 0
        else
            print_error "Session already exists. Use -a to attach or choose different name with -s"
            exit 1
        fi
    fi
fi

# Create new tmux session (detached)
echo "Creating tmux session: $SESSION_NAME"
tmux new-session -d -s "$SESSION_NAME" -n "ssh"

# Get the actual window index (might be 0 or 1 depending on tmux config)
SSH_WINDOW=$(tmux list-windows -t "$SESSION_NAME" -F "#{window_index}" | head -n1)

# Create SSH panes based on node count
create_ssh_panes "$SSH_WINDOW" "ssh"

# Create second SSH window if dual-ssh is enabled
if [[ "$DUAL_SSH" == true ]]; then
    echo "Creating second SSH window..."
    tmux new-window -t "$SESSION_NAME" -n "ssh2"
    SSH2_WINDOW=$(tmux list-windows -t "$SESSION_NAME" -F "#{window_index}:#{window_name}" | grep ":ssh2" | cut -d: -f1)
    create_ssh_panes "$SSH2_WINDOW" "ssh2"
fi

# Create BMC window if requested
if [[ "$CREATE_BMC" == true ]]; then
    echo "Creating BMC SSH window..."
    tmux new-window -t "$SESSION_NAME" -n "bmc"
    BMC_WINDOW=$(tmux list-windows -t "$SESSION_NAME" -F "#{window_index}:#{window_name}" | grep ":bmc$" | cut -d: -f1)
    create_bmc_panes "$BMC_WINDOW" "bmc"
fi

# Create console windows if requested
if [[ "$CREATE_CONSOLE" == true ]]; then
    create_console_windows "console" "console"
fi

# Create SUC console windows if requested
if [[ "$CREATE_SUC" == true ]]; then
    create_console_windows "suc" "suc"
fi

# Ensure SSH window is selected as default
tmux select-window -t "$SESSION_NAME:$SSH_WINDOW"

# Attach to session or provide instructions
print_success "Tmux session '$SESSION_NAME' created successfully"
echo ""
echo "Windows:"
tmux list-windows -t "$SESSION_NAME" -F "  #{window_index}: #{window_name}"
echo ""

# Check if we're already inside a tmux session
if [[ -n "${TMUX:-}" ]]; then
    # Already in tmux - don't nest sessions
    print_success "Session created. To switch to it:"
    echo "  tmux switch-client -t $SESSION_NAME"
    echo ""
    echo "Or detach from current session (Ctrl-b d) and run:"
    echo "  tmux attach -t $SESSION_NAME"
else
    # Not in tmux - attach to the new session
    echo "Attaching to session..."
    tmux attach -t "$SESSION_NAME"
fi
