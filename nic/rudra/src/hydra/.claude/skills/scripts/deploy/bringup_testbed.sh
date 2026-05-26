#!/bin/bash
#
# bringup_testbed.sh - Wait for NIC to come up and run setup commands
#
# This script:
#   1. Waits for the NIC to come back up (polls nicctl show card)
#   2. Runs per-node setup commands defined in the testbed YAML
#

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARSER_SCRIPT="$SCRIPT_DIR/../testbed/parse_testbed.py"

# Default options
TESTBED_FILE=""
WAIT_TIMEOUT=300  # 5 minutes default
POLL_INTERVAL=10  # seconds between polls
DRY_RUN=false
SKIP_WAIT=false
PARALLEL=false

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
    echo -e "${GREEN}$1${NC}"
}

function print_warning() {
    echo -e "${YELLOW}Warning: $1${NC}"
}

function print_info() {
    echo -e "${BLUE}$1${NC}"
}

function usage() {
    cat << EOF
Usage: $(basename "$0") <testbed_yaml_file> [options]

Wait for NICs to come up and run per-node setup commands.

This script polls 'nicctl show card' until the NIC is ready, then runs
any setup_commands defined in the testbed YAML for each node.

Arguments:
  testbed_yaml_file         Path to testbed YAML configuration file

Options:
  -t, --timeout SECONDS     Timeout waiting for NIC (default: 300)
  -i, --interval SECONDS    Poll interval (default: 10)
  -s, --skip-wait           Skip waiting for NIC, just run setup commands
  -p, --parallel            Bring up all hosts in parallel
  -n, --dry-run             Show what would be done without executing
  -h, --help                Show this help message

Testbed YAML Format:
  Add 'setup_commands' to each node that needs post-reset setup:

  nodes:
    - name: node1
      ip: <NODE1_IP>
      username: <SSH_USER>
      password: <SSH_PASSWORD>
      setup_commands:
        - "modprobe ionic_rdma"
        - "/opt/scripts/setup_node.sh"

    - name: node2
      ip: <NODE2_IP>
      username: <SSH_USER>
      password: <SSH_PASSWORD>
      setup_commands:
        - "modprobe ionic_rdma"
        - "/opt/scripts/setup_node.sh --option2"

Examples:
  # Wait for NICs and run setup commands
  $(basename "$0") /vol/systest/hydra/testbeds/prateek.yml

  # Custom timeout (10 minutes)
  $(basename "$0") /vol/systest/hydra/testbeds/prateek.yml --timeout 600

  # Skip NIC wait, just run setup commands
  $(basename "$0") /vol/systest/hydra/testbeds/prateek.yml --skip-wait

  # Bring up all hosts in parallel
  $(basename "$0") /vol/systest/hydra/testbeds/prateek.yml --parallel

  # Dry run
  $(basename "$0") /vol/systest/hydra/testbeds/prateek.yml -n

EOF
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            ;;
        -t|--timeout)
            WAIT_TIMEOUT="$2"
            shift 2
            ;;
        -i|--interval)
            POLL_INTERVAL="$2"
            shift 2
            ;;
        -s|--skip-wait)
            SKIP_WAIT=true
            shift
            ;;
        -p|--parallel)
            PARALLEL=true
            shift
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
                print_error "Too many arguments"
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

echo "========================================"
echo "Testbed Bringup"
echo "========================================"
echo "Testbed: $TESTBED_NAME"
echo "Nodes: $NODE_COUNT"
echo "Wait timeout: ${WAIT_TIMEOUT}s"
echo "Poll interval: ${POLL_INTERVAL}s"
echo "========================================"
echo ""

# Function to get node info by index
function get_node_field() {
    local idx=$1
    local field=$2
    echo "$TESTBED_JSON" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data['nodes'][$idx]['$field'])"
}

# Function to get setup commands count
function get_setup_commands_count() {
    local idx=$1
    echo "$TESTBED_JSON" | python3 -c "import sys, json; data=json.load(sys.stdin); print(len(data['nodes'][$idx]['setup_commands']))"
}

# Function to get a specific setup command
function get_setup_command() {
    local node_idx=$1
    local cmd_idx=$2
    echo "$TESTBED_JSON" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data['nodes'][$node_idx]['setup_commands'][$cmd_idx])"
}

# Function to run SSH command
function run_ssh_command() {
    local ip=$1
    local username=$2
    local password=$3
    local command=$4

    if [[ -n "$password" ]]; then
        if command -v sshpass &> /dev/null; then
            sshpass -p "$password" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "${username}@${ip}" "$command"
        else
            ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "${username}@${ip}" "$command"
        fi
    else
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "${username}@${ip}" "$command"
    fi
}

# Function to check if NIC is up
function check_nic_status() {
    local ip=$1
    local username=$2
    local password=$3

    # Try to run nicctl show card and check if it succeeds
    local output
    if output=$(run_ssh_command "$ip" "$username" "$password" "nicctl show card" 2>&1); then
        # Check if output indicates card is ready (not in reset state)
        if echo "$output" | grep -qi "state.*up\|state.*ready\|operational"; then
            return 0
        fi
        # If we got output but no clear "up" state, still consider it up
        # (the exact output format may vary)
        if [[ -n "$output" ]] && ! echo "$output" | grep -qi "error\|fail\|reset\|offline"; then
            return 0
        fi
    fi
    return 1
}

# Function to wait for NIC to come up
function wait_for_nic() {
    local node_name=$1
    local node_ip=$2
    local node_user=$3
    local node_pass=$4

    local elapsed=0

    print_info "[$node_name] Waiting for NIC to come up..."

    while [[ $elapsed -lt $WAIT_TIMEOUT ]]; do
        if check_nic_status "$node_ip" "$node_user" "$node_pass"; then
            print_success "[$node_name] NIC is up (waited ${elapsed}s)"
            return 0
        fi

        sleep "$POLL_INTERVAL"
        elapsed=$((elapsed + POLL_INTERVAL))
        echo "[$node_name] Still waiting... (${elapsed}s / ${WAIT_TIMEOUT}s)"
    done

    print_error "[$node_name] Timeout waiting for NIC after ${WAIT_TIMEOUT}s"
    return 1
}

# Function to run setup commands for a node
function run_setup_commands() {
    local idx=$1
    local node_name=$2
    local node_ip=$3
    local node_user=$4
    local node_pass=$5

    local cmd_count
    cmd_count=$(get_setup_commands_count "$idx")

    if [[ "$cmd_count" -eq 0 ]]; then
        print_info "[$node_name] No setup commands defined"
        return 0
    fi

    print_info "[$node_name] Running $cmd_count setup command(s)..."

    for ((j=0; j<cmd_count; j++)); do
        local cmd
        cmd=$(get_setup_command "$idx" "$j")

        if [[ "$DRY_RUN" == true ]]; then
            print_info "[$node_name] Would run: $cmd"
        else
            echo "[$node_name] Running: $cmd"
            if ! run_ssh_command "$node_ip" "$node_user" "$node_pass" "$cmd"; then
                print_error "[$node_name] Command failed: $cmd"
                return 1
            fi
            print_success "[$node_name] Command succeeded"
        fi
    done

    return 0
}

# Function to bring up a single node
function bringup_node() {
    local idx=$1
    local node_name=$2
    local node_ip=$3
    local node_user=$4
    local node_pass=$5

    echo "----------------------------------------"
    print_info "[$node_name] Starting bringup for ${node_user}@${node_ip}"
    echo "----------------------------------------"

    # Step 1: Wait for NIC (unless skipped)
    if [[ "$SKIP_WAIT" != true ]]; then
        if [[ "$DRY_RUN" == true ]]; then
            print_info "[$node_name] Would wait for NIC to come up"
        else
            if ! wait_for_nic "$node_name" "$node_ip" "$node_user" "$node_pass"; then
                return 1
            fi
        fi
    else
        print_info "[$node_name] Skipping NIC wait"
    fi

    # Step 2: Run setup commands
    if ! run_setup_commands "$idx" "$node_name" "$node_ip" "$node_user" "$node_pass"; then
        return 1
    fi

    print_success "[$node_name] Bringup complete"
    return 0
}

# Track success/failure
FAILED_NODES=()
SUCCESS_COUNT=0

if [[ "$PARALLEL" == true ]]; then
    echo "Bringing up nodes in parallel..."
    echo ""

    # Create temp directory for status files
    TEMP_DIR=$(mktemp -d)
    trap "rm -rf $TEMP_DIR" EXIT

    # Launch all bringups in parallel
    PIDS=()
    for ((i=0; i<NODE_COUNT; i++)); do
        NODE_NAME=$(get_node_field $i "name")
        NODE_IP=$(get_node_field $i "ip")
        NODE_USER=$(get_node_field $i "username")
        NODE_PASS=$(get_node_field $i "password")

        (
            if bringup_node $i "$NODE_NAME" "$NODE_IP" "$NODE_USER" "$NODE_PASS"; then
                echo "success" > "$TEMP_DIR/$NODE_NAME.status"
            else
                echo "failed" > "$TEMP_DIR/$NODE_NAME.status"
            fi
        ) &
        PIDS+=($!)
    done

    # Wait for all bringups to complete
    for pid in "${PIDS[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    # Collect results
    for ((i=0; i<NODE_COUNT; i++)); do
        NODE_NAME=$(get_node_field $i "name")
        if [[ -f "$TEMP_DIR/$NODE_NAME.status" && "$(cat "$TEMP_DIR/$NODE_NAME.status")" == "success" ]]; then
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        else
            FAILED_NODES+=("$NODE_NAME")
        fi
    done
else
    echo "Bringing up nodes sequentially..."
    echo ""

    for ((i=0; i<NODE_COUNT; i++)); do
        NODE_NAME=$(get_node_field $i "name")
        NODE_IP=$(get_node_field $i "ip")
        NODE_USER=$(get_node_field $i "username")
        NODE_PASS=$(get_node_field $i "password")

        if bringup_node $i "$NODE_NAME" "$NODE_IP" "$NODE_USER" "$NODE_PASS"; then
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        else
            FAILED_NODES+=("$NODE_NAME")
        fi
        echo ""
    done
fi

# Summary
echo "========================================"
echo "Bringup Summary"
echo "========================================"
echo "Total nodes: $NODE_COUNT"
echo "Successful: $SUCCESS_COUNT"
echo "Failed: ${#FAILED_NODES[@]}"

if [[ ${#FAILED_NODES[@]} -gt 0 ]]; then
    print_error "Failed nodes: ${FAILED_NODES[*]}"
    exit 1
else
    if [[ "$DRY_RUN" == true ]]; then
        print_success "Dry run complete - no actual changes made"
    else
        print_success "All nodes brought up successfully"
    fi
fi
