#!/bin/bash
#
# run_commands.sh - Execute commands on testbed hosts via SSH with input automation
#
# This script connects to testbed hosts and runs commands with support for
# automated input responses (for interactive prompts).
#

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARSER_SCRIPT="$SCRIPT_DIR/parse_testbed.py"

# Default options
TESTBED_FILE=""
COMMANDS=()
INPUT_STRING=""
DRY_RUN=false
QUIET=false
STOP_ON_ERROR=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

function print_error() {
    echo -e "${RED}Error: $1${NC}" >&2
}

function print_success() {
    if [[ "$QUIET" != true ]]; then
        echo -e "${GREEN}$1${NC}"
    fi
}

function print_warning() {
    if [[ "$QUIET" != true ]]; then
        echo -e "${YELLOW}Warning: $1${NC}"
    fi
}

function print_info() {
    if [[ "$QUIET" != true ]]; then
        echo -e "${BLUE}$1${NC}"
    fi
}

function usage() {
    cat << EOF
Usage: $(basename "$0") <testbed_yaml_file> [options] <command> [command...]

Execute commands on all hosts in a testbed via SSH.

Arguments:
  testbed_yaml_file         Path to testbed YAML configuration file
  command                   Command(s) to execute on each host

Options:
  -i, --input STRING        Input to send to commands (use \\n for newlines)
                            The input is piped to stdin of the remote command
  -n, --dry-run             Show what would be done without executing
  -q, --quiet               Suppress informational output
  -s, --stop-on-error       Stop execution on first error
  -h, --help                Show this help message

Examples:
  # Run a simple command on all nodes
  $(basename "$0") /vol/systest/hydra/testbeds/prateek.yml "hostname"

  # Run multiple commands (executed in order)
  $(basename "$0") /vol/systest/hydra/testbeds/prateek.yml "hostname" "uptime"

  # Provide input to interactive commands
  $(basename "$0") /vol/systest/hydra/testbeds/prateek.yml --input "y\\n" "sudo apt update"

  # Multiple inputs (sent in order, newline-separated)
  $(basename "$0") /vol/systest/hydra/testbeds/prateek.yml --input "password123\\ny\\n" "sudo some-command"

  # Dry run to see what would be executed
  $(basename "$0") /vol/systest/hydra/testbeds/prateek.yml -n "reboot"

  # Quiet mode (only show command output)
  $(basename "$0") /vol/systest/hydra/testbeds/prateek.yml -q "cat /etc/hostname"

  # Stop on first error
  $(basename "$0") /vol/systest/hydra/testbeds/prateek.yml -s "critical-command"

EOF
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            ;;
        -i|--input)
            INPUT_STRING="$2"
            shift 2
            ;;
        -n|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -q|--quiet)
            QUIET=true
            shift
            ;;
        -s|--stop-on-error)
            STOP_ON_ERROR=true
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
                COMMANDS+=("$1")
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

if [[ ${#COMMANDS[@]} -eq 0 ]]; then
    print_error "No commands specified"
    usage
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

# Validate testbed file exists
if [[ ! -f "$TESTBED_FILE" ]]; then
    print_error "Testbed file not found: $TESTBED_FILE"
    exit 1
fi

# Parse testbed YAML
if [[ "$QUIET" != true ]]; then
    echo "Parsing testbed configuration..."
fi
TESTBED_JSON=$(python3 "$PARSER_SCRIPT" "$TESTBED_FILE")
if [[ $? -ne 0 ]]; then
    print_error "Failed to parse testbed YAML"
    exit 1
fi

# Extract testbed info
TESTBED_NAME=$(echo "$TESTBED_JSON" | python3 -c "import sys, json; print(json.load(sys.stdin)['name'])")
NODE_COUNT=$(echo "$TESTBED_JSON" | python3 -c "import sys, json; print(len(json.load(sys.stdin)['nodes']))")

if [[ "$QUIET" != true ]]; then
    echo "========================================"
    echo "Run Commands on Testbed"
    echo "========================================"
    echo "Testbed: $TESTBED_NAME"
    echo "Nodes: $NODE_COUNT"
    echo "Commands: ${#COMMANDS[@]}"
    for cmd in "${COMMANDS[@]}"; do
        echo "  - $cmd"
    done
    if [[ -n "$INPUT_STRING" ]]; then
        echo "Input: (provided)"
    fi
    echo "========================================"
    echo ""
fi

# Function to get node info by index
function get_node_field() {
    local idx=$1
    local field=$2
    echo "$TESTBED_JSON" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data['nodes'][$idx]['$field'])"
}

# Function to run a command on a node
function run_on_node() {
    local node_ip=$1
    local node_user=$2
    local node_pass=$3
    local command=$4

    local ssh_opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

    if [[ -n "$INPUT_STRING" ]]; then
        # With input automation - use echo -e to interpret escape sequences
        if [[ -n "$node_pass" ]]; then
            if command -v sshpass &> /dev/null; then
                echo -e "$INPUT_STRING" | sshpass -p "$node_pass" ssh $ssh_opts "${node_user}@${node_ip}" "$command"
            else
                print_warning "sshpass not installed, password auth may fail"
                echo -e "$INPUT_STRING" | ssh $ssh_opts "${node_user}@${node_ip}" "$command"
            fi
        else
            echo -e "$INPUT_STRING" | ssh $ssh_opts "${node_user}@${node_ip}" "$command"
        fi
    else
        # Simple command execution without input
        if [[ -n "$node_pass" ]]; then
            if command -v sshpass &> /dev/null; then
                sshpass -p "$node_pass" ssh $ssh_opts "${node_user}@${node_ip}" "$command"
            else
                print_warning "sshpass not installed, password auth may fail"
                ssh $ssh_opts "${node_user}@${node_ip}" "$command"
            fi
        else
            ssh $ssh_opts "${node_user}@${node_ip}" "$command"
        fi
    fi
}

# Track success/failure
FAILED_NODES=()
SUCCESS_COUNT=0

# Process nodes sequentially
for ((i=0; i<NODE_COUNT; i++)); do
    NODE_NAME=$(get_node_field $i "name")
    NODE_IP=$(get_node_field $i "ip")
    NODE_USER=$(get_node_field $i "username")
    NODE_PASS=$(get_node_field $i "password")

    if [[ "$QUIET" != true ]]; then
        echo "----------------------------------------"
        print_info "[$NODE_NAME] Connecting to ${NODE_USER}@${NODE_IP}"
        echo "----------------------------------------"
    fi

    NODE_FAILED=false

    for cmd in "${COMMANDS[@]}"; do
        if [[ "$DRY_RUN" == true ]]; then
            print_info "[$NODE_NAME] Would run: $cmd"
            if [[ -n "$INPUT_STRING" ]]; then
                print_info "[$NODE_NAME] With input: $(echo -e "$INPUT_STRING" | head -c 50)..."
            fi
        else
            if [[ "$QUIET" != true ]]; then
                print_info "[$NODE_NAME] Running: $cmd"
            fi

            if ! run_on_node "$NODE_IP" "$NODE_USER" "$NODE_PASS" "$cmd"; then
                print_error "[$NODE_NAME] Command failed: $cmd"
                NODE_FAILED=true

                if [[ "$STOP_ON_ERROR" == true ]]; then
                    print_error "Stopping due to --stop-on-error"
                    exit 1
                fi

                # Skip remaining commands for this node
                break
            fi
        fi
    done

    if [[ "$NODE_FAILED" == true ]]; then
        FAILED_NODES+=("$NODE_NAME")
    else
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        if [[ "$QUIET" != true && "$DRY_RUN" != true ]]; then
            print_success "[$NODE_NAME] All commands completed"
        fi
    fi

    if [[ "$QUIET" != true ]]; then
        echo ""
    fi
done

# Summary
if [[ "$QUIET" != true ]]; then
    echo "========================================"
    echo "Summary"
    echo "========================================"
    echo "Total nodes: $NODE_COUNT"
    echo "Successful: $SUCCESS_COUNT"
    echo "Failed: ${#FAILED_NODES[@]}"
fi

if [[ ${#FAILED_NODES[@]} -gt 0 ]]; then
    print_error "Failed nodes: ${FAILED_NODES[*]}"
    exit 1
else
    if [[ "$DRY_RUN" == true ]]; then
        print_success "Dry run complete - no actual changes made"
    elif [[ "$QUIET" != true ]]; then
        print_success "All commands completed successfully"
    fi
fi
