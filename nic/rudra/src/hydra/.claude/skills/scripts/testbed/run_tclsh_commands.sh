#!/bin/bash
#
# run_tclsh_commands.sh - Run tcl commands on all NICs in a testbed
#
# This script connects to each node, gets all card IDs, and runs the specified
# tcl commands on each card using tcl-host.sh.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARSER_SCRIPT="$SCRIPT_DIR/parse_testbed.py"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

function print_error() {
    echo -e "${RED}Error: $1${NC}" >&2
}

function print_success() {
    echo -e "${GREEN}$1${NC}"
}

function print_info() {
    echo -e "${BLUE}$1${NC}"
}

function usage() {
    cat << EOF
Usage: $(basename "$0") <testbed_yaml_file> <tcl_command> [tcl_command...]

Run tcl commands on all NICs in a testbed via tcl-host.sh.

This script:
  1. Connects to each node in the testbed
  2. Gets all card IDs via 'nicctl show card'
  3. For each card, runs tcl-host.sh and executes the specified tcl commands

Arguments:
  testbed_yaml_file         Path to testbed YAML configuration file
  tcl_command               Tcl command(s) to run (executed in order)

Options:
  -o, --output FILE         Save output to file (also prints to screen)
  -d, --tclsh-dir DIR       Directory containing tcl-host.sh on the remote node.
                            Required: pass --tclsh-dir or export TCLSH_DIR.
  -n, --dry-run             Show what would be done without executing
  -h, --help                Show this help message

Examples:
  # Run interrupt check on all NICs
  $(basename "$0") /vol/systest/hydra/testbeds/smc12.yml "vul_top_intr_check 0 0 none"

  # Run multiple tcl commands
  $(basename "$0") /vol/systest/hydra/testbeds/smc12.yml "vul_top_intr_check 0 0 none" "some_other_cmd"

  # Save output to a file
  $(basename "$0") /vol/systest/hydra/testbeds/smc12.yml -o output.log "vul_top_intr_check 0 0 none"

  # Use a different tclsh directory
  $(basename "$0") /vol/systest/hydra/testbeds/smc12.yml -d /opt/tclsh "vul_top_intr_check 0 0 none"

  # Dry run
  $(basename "$0") /vol/systest/hydra/testbeds/smc12.yml -n "vul_top_intr_check 0 0 none"

EOF
    exit 0
}

# Defaults
TESTBED_FILE=""
TCL_COMMANDS=()
OUTPUT_FILE=""
TCLSH_DIR="${TCLSH_DIR:-}"
DRY_RUN=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            ;;
        -o|--output)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        -d|--tclsh-dir)
            TCLSH_DIR="$2"
            shift 2
            ;;
        -n|--dry-run)
            DRY_RUN=true
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
                TCL_COMMANDS+=("$1")
            fi
            shift
            ;;
    esac
done

# Validate
if [[ -z "$TESTBED_FILE" ]]; then
    print_error "Missing testbed YAML file"
    usage
fi

if [[ ! -f "$TESTBED_FILE" ]]; then
    print_error "Testbed file not found: $TESTBED_FILE"
    exit 1
fi

if [[ ${#TCL_COMMANDS[@]} -eq 0 ]]; then
    print_error "No tcl commands specified"
    usage
fi

if [[ -z "$TCLSH_DIR" ]]; then
    print_error "tclsh dir not set: pass --tclsh-dir or export TCLSH_DIR"
    exit 1
fi

# Check dependencies
if ! command -v python3 &> /dev/null; then
    print_error "python3 is not installed"
    exit 1
fi

if [[ ! -f "$PARSER_SCRIPT" ]]; then
    print_error "Parser script not found: $PARSER_SCRIPT"
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

echo "========================================"
echo "Run Tcl Commands on Testbed NICs"
echo "========================================"
echo "Testbed: $TESTBED_NAME"
echo "Nodes: $NODE_COUNT"
echo "Tclsh dir: $TCLSH_DIR"
echo "Tcl commands:"
for cmd in "${TCL_COMMANDS[@]}"; do
    echo "  - $cmd"
done
echo "========================================"
echo ""

# Function to get node info by index
function get_node_field() {
    local idx=$1
    local field=$2
    echo "$TESTBED_JSON" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data['nodes'][$idx]['$field'])"
}

# Build the tcl commands string for heredoc
TCL_CMDS_STR='source "$::env(ASIC_SRC)/ip/cosim/tclsh/.tclrc.diag.vul.x86"'
for cmd in "${TCL_COMMANDS[@]}"; do
    TCL_CMDS_STR="$TCL_CMDS_STR
$cmd"
done
TCL_CMDS_STR="$TCL_CMDS_STR
exit"

# Build the full remote command with colored card ID output
# Filter out the "asic_tclsh: No such file or directory" error from tcl-host.sh
REMOTE_CMD="cd $TCLSH_DIR && for CARD in \$(nicctl show card | grep -E \"^[0-9a-fA-F]{8}-\" | awk '{print \$1}'); do echo \"\"; echo -e \"\033[1;36m########################################\033[0m\"; echo -e \"\033[1;36m# Card: \$CARD\033[0m\"; echo -e \"\033[1;36m########################################\033[0m\"; PAL_CARD_UUID=\$CARD ./tcl-host.sh << 'TCLEOF' 2>&1 | grep -v 'asic_tclsh: No such file or directory'
$TCL_CMDS_STR
TCLEOF
done"

# Function to run on a node
function run_on_node() {
    local node_ip=$1
    local node_user=$2
    local node_pass=$3

    local ssh_opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

    if [[ -n "$node_pass" ]]; then
        if command -v sshpass &> /dev/null; then
            sshpass -p "$node_pass" ssh $ssh_opts "${node_user}@${node_ip}" "$REMOTE_CMD"
        else
            echo -e "${YELLOW}Warning: sshpass not installed, password auth may fail${NC}"
            ssh $ssh_opts "${node_user}@${node_ip}" "$REMOTE_CMD"
        fi
    else
        ssh $ssh_opts "${node_user}@${node_ip}" "$REMOTE_CMD"
    fi
}

# Main execution function
function main() {
    for ((i=0; i<NODE_COUNT; i++)); do
        NODE_NAME=$(get_node_field $i "name")
        NODE_IP=$(get_node_field $i "ip")
        NODE_USER=$(get_node_field $i "username")
        NODE_PASS=$(get_node_field $i "password")

        echo "========================================"
        print_info "[$NODE_NAME] Connecting to ${NODE_USER}@${NODE_IP}"
        echo "========================================"

        if [[ "$DRY_RUN" == true ]]; then
            print_info "[$NODE_NAME] Would run tcl commands on all cards"
            echo "Commands:"
            for cmd in "${TCL_COMMANDS[@]}"; do
                echo "  $cmd"
            done
        else
            # Run and ignore exit code (tcl-host.sh segfaults on exit)
            run_on_node "$NODE_IP" "$NODE_USER" "$NODE_PASS" || true
            print_success "[$NODE_NAME] Completed"
        fi

        echo ""
    done

    echo "========================================"
    if [[ "$DRY_RUN" == true ]]; then
        print_success "Dry run complete"
    else
        print_success "All nodes completed"
    fi
    echo "========================================"
}

# Run with optional output file
if [[ -n "$OUTPUT_FILE" ]]; then
    main 2>&1 | tee "$OUTPUT_FILE"
    echo ""
    print_success "Output saved to: $OUTPUT_FILE"
else
    main
fi
