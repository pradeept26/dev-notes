#!/bin/bash
#
# deploy_firmware.sh - Deploy firmware to NICs on testbed hosts
#
# This script:
#   1. Transfers the firmware image to all hosts in the testbed
#   2. Runs nicctl update firmware on each host
#   3. Optionally resets the NIC
#

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARSER_SCRIPT="$SCRIPT_DIR/../testbed/parse_testbed.py"

# Source utility libraries
source "$SCRIPT_DIR/../lib/nicctl_utils.sh"

# Default options
TESTBED_FILE=""
IMAGE_FILE=""
REMOTE_PATH="/tmp"
RESET_NIC=false
RESET_ONLY=false
TRANSFER_ONLY=false
UPDATE_ONLY=false
PARALLEL=false
DRY_RUN=false
REMOTE_IMAGE_PATH=""  # Set if using --update-only
NODE_FILTER=""  # Comma-separated list of node names to target
NIC_INTERFACE=""  # Specific NIC interface (e.g., benic1) to target

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
Usage: $(basename "$0") <testbed_yaml_file> <image_file> [options]

Deploy firmware to NICs on all hosts in a testbed.

This script transfers the firmware image and runs:
  nicctl update firmware -i <image>
  nicctl reset card --all  (if --reset is specified)

Arguments:
  testbed_yaml_file         Path to testbed YAML configuration file
  image_file                Path to the firmware image file (local or remote with --update-only)

Options:
  -d, --dest PATH           Remote destination path (default: /tmp)
  -r, --reset               Reset NIC after firmware update
  -R, --reset-only          Only reset NICs (no transfer, no firmware update)
  -t, --transfer-only       Only transfer the image, don't update firmware
  -u, --update-only         Only update firmware (image already on remote hosts)
                            When using this, image_file is the remote path
  -p, --parallel            Deploy to all hosts in parallel
  -N, --node <name>         Only target specific node(s) (comma-separated)
  -I, --interface <name>    Only target specific NIC interface (e.g., benic1p1)
                            Uses nicctl show lif to get card UUID for that interface
  -n, --dry-run             Show what would be done without executing
  -h, --help                Show this help message

Examples:
  # Transfer and update firmware (no reset)
  $(basename "$0") /vol/systest/hydra/testbeds/prateek.yml ./ainic_fw.tar

  # Transfer, update, and reset NIC
  $(basename "$0") /vol/systest/hydra/testbeds/prateek.yml ./ainic_fw.tar --reset

  # Deploy in parallel to all hosts
  $(basename "$0") /vol/systest/hydra/testbeds/prateek.yml ./ainic_fw.tar --reset --parallel

  # Only reset NICs (no transfer, no firmware update)
  $(basename "$0") /vol/systest/hydra/testbeds/prateek.yml --reset-only

  # Only transfer the image
  $(basename "$0") /vol/systest/hydra/testbeds/prateek.yml ./ainic_fw.tar --transfer-only

  # Only update (image already transferred to /tmp)
  $(basename "$0") /vol/systest/hydra/testbeds/prateek.yml /tmp/ainic_fw.tar --update-only --reset

  # Dry run
  $(basename "$0") /vol/systest/hydra/testbeds/prateek.yml ./ainic_fw.tar --reset -n

  # Deploy only to specific node
  $(basename "$0") /vol/systest/hydra/testbeds/kenya-perf-34.yml ./ainic_fw.tar --reset --node node1

  # Deploy only to specific NIC interface
  $(basename "$0") /vol/systest/hydra/testbeds/prateek.yml ./ainic_fw.tar --reset --interface benic1p1

EOF
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            ;;
        -d|--dest)
            REMOTE_PATH="$2"
            shift 2
            ;;
        -r|--reset)
            RESET_NIC=true
            shift
            ;;
        -R|--reset-only)
            RESET_ONLY=true
            RESET_NIC=true
            shift
            ;;
        -t|--transfer-only)
            TRANSFER_ONLY=true
            shift
            ;;
        -u|--update-only)
            UPDATE_ONLY=true
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
        -N|--node)
            NODE_FILTER="$2"
            shift 2
            ;;
        -I|--interface)
            NIC_INTERFACE="$2"
            shift 2
            ;;
        -*)
            print_error "Unknown option: $1"
            usage
            ;;
        *)
            if [[ -z "$TESTBED_FILE" ]]; then
                TESTBED_FILE="$1"
            elif [[ -z "$IMAGE_FILE" ]]; then
                IMAGE_FILE="$1"
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

# Image file is not required for --reset-only
if [[ -z "$IMAGE_FILE" && "$RESET_ONLY" != true ]]; then
    print_error "Missing image file"
    usage
fi

# Check for conflicting options
if [[ "$TRANSFER_ONLY" == true && "$UPDATE_ONLY" == true ]]; then
    print_error "Cannot use both --transfer-only and --update-only"
    exit 1
fi

if [[ "$RESET_ONLY" == true && "$TRANSFER_ONLY" == true ]]; then
    print_error "Cannot use both --reset-only and --transfer-only"
    exit 1
fi

if [[ "$RESET_ONLY" == true && "$UPDATE_ONLY" == true ]]; then
    print_error "Cannot use both --reset-only and --update-only"
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

# Validate testbed file exists
if [[ ! -f "$TESTBED_FILE" ]]; then
    print_error "Testbed file not found: $TESTBED_FILE"
    exit 1
fi

# Validate image file exists (only if not update-only or reset-only mode)
if [[ "$UPDATE_ONLY" != true && "$RESET_ONLY" != true && ! -f "$IMAGE_FILE" ]]; then
    print_error "Image file not found: $IMAGE_FILE"
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

# Determine remote image path (not needed for reset-only)
if [[ "$RESET_ONLY" != true ]]; then
    if [[ "$UPDATE_ONLY" == true ]]; then
        REMOTE_IMAGE_PATH="$IMAGE_FILE"
        IMAGE_BASENAME=$(basename "$IMAGE_FILE")
    else
        IMAGE_BASENAME=$(basename "$IMAGE_FILE")
        IMAGE_SIZE=$(du -h "$IMAGE_FILE" | cut -f1)
        REMOTE_IMAGE_PATH="${REMOTE_PATH}/${IMAGE_BASENAME}"
    fi
fi

echo "========================================"
echo "Firmware Deployment"
echo "========================================"
echo "Testbed: $TESTBED_NAME"
if [[ -n "$NODE_FILTER" ]]; then
    echo "Nodes: $NODE_COUNT total (targeting: $NODE_FILTER)"
else
    echo "Nodes: $NODE_COUNT"
fi
if [[ -n "$NIC_INTERFACE" ]]; then
    echo "Interface: $NIC_INTERFACE (will lookup card UUID)"
fi
if [[ "$RESET_ONLY" != true && "$UPDATE_ONLY" != true ]]; then
    echo "Image: $IMAGE_BASENAME ($IMAGE_SIZE)"
    echo "Remote path: $REMOTE_PATH"
fi
if [[ "$RESET_ONLY" != true ]]; then
    echo "Remote image: $REMOTE_IMAGE_PATH"
fi
echo ""
echo "Actions:"
if [[ "$RESET_ONLY" == true ]]; then
    echo "  - Reset NIC only: nicctl reset card --all"
elif [[ "$UPDATE_ONLY" != true && "$TRANSFER_ONLY" != true ]]; then
    echo "  - Transfer image"
    echo "  - Update firmware: nicctl update firmware -i $REMOTE_IMAGE_PATH"
    if [[ "$RESET_NIC" == true ]]; then
        echo "  - Reset NIC: nicctl reset card --all"
    fi
elif [[ "$UPDATE_ONLY" == true ]]; then
    echo "  - Skip transfer (update-only mode)"
    echo "  - Update firmware: nicctl update firmware -i $REMOTE_IMAGE_PATH"
    if [[ "$RESET_NIC" == true ]]; then
        echo "  - Reset NIC: nicctl reset card --all"
    fi
elif [[ "$TRANSFER_ONLY" == true ]]; then
    echo "  - Transfer only (no firmware update)"
fi
echo "========================================"
echo ""

# Function to get node info by index
function get_node_field() {
    local idx=$1
    local field=$2
    echo "$TESTBED_JSON" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data['nodes'][$idx]['$field'])"
}

# Function to check if a node should be processed based on NODE_FILTER
function should_process_node() {
    local node_name=$1

    # If no filter, process all nodes
    if [[ -z "$NODE_FILTER" ]]; then
        return 0
    fi

    # Check if node_name is in the comma-separated filter list
    IFS=',' read -ra FILTER_NODES <<< "$NODE_FILTER"
    for filter_node in "${FILTER_NODES[@]}"; do
        # Trim whitespace
        filter_node=$(echo "$filter_node" | xargs)
        if [[ "$node_name" == "$filter_node" ]]; then
            return 0
        fi
    done

    return 1
}

# Function to run SSH command
function run_ssh_command() {
    local ip=$1
    local username=$2
    local password=$3
    local command=$4

    if [[ -n "$password" ]]; then
        if command -v sshpass &> /dev/null; then
            sshpass -p "$password" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${username}@${ip}" "$command"
        else
            print_warning "sshpass not installed, password auth may fail"
            ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${username}@${ip}" "$command"
        fi
    else
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${username}@${ip}" "$command"
    fi
}

# Function to run SCP
function run_scp() {
    local ip=$1
    local username=$2
    local password=$3
    local src_file=$4
    local dest_path=$5

    local remote_dest="${username}@${ip}:${dest_path}/"

    if [[ -n "$password" ]]; then
        if command -v sshpass &> /dev/null; then
            sshpass -p "$password" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$src_file" "$remote_dest"
        else
            print_warning "sshpass not installed, password auth may fail"
            scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$src_file" "$remote_dest"
        fi
    else
        scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$src_file" "$remote_dest"
    fi
}

# Function to deploy to a single node
function deploy_to_node() {
    local idx=$1
    local node_name=$2
    local node_ip=$3
    local node_user=$4
    local node_pass=$5

    echo "----------------------------------------"
    print_info "[$node_name] Starting deployment to ${node_user}@${node_ip}"
    echo "----------------------------------------"

    # Get card UUID if interface is specified
    local CARD_UUID=""
    if [[ -n "$NIC_INTERFACE" ]]; then
        print_info "[$node_name] Getting card UUID for interface $NIC_INTERFACE..."
        CARD_UUID=$(get_card_uuid_for_interface "$node_ip" "$node_user" "$node_pass" "$NIC_INTERFACE" "run_ssh_command")
        if [[ $? -ne 0 || -z "$CARD_UUID" ]]; then
            print_error "[$node_name] Failed to get card UUID for interface $NIC_INTERFACE"
            return 1
        fi
        print_info "[$node_name] Found card UUID: $CARD_UUID"
    fi

    # Handle reset-only mode
    if [[ "$RESET_ONLY" == true ]]; then
        local reset_cmd
        if [[ -n "$CARD_UUID" ]]; then
            reset_cmd="sudo nicctl reset card -c $CARD_UUID"
        else
            reset_cmd="sudo nicctl reset card --all"
        fi

        if [[ "$DRY_RUN" == true ]]; then
            print_info "[$node_name] Would run: $reset_cmd"
        else
            print_info "[$node_name] Resetting NIC..."
            if ! run_ssh_command "$node_ip" "$node_user" "$node_pass" "$reset_cmd"; then
                print_error "[$node_name] NIC reset failed"
                return 1
            fi
            print_success "[$node_name] NIC reset complete"
        fi

        print_success "[$node_name] Reset complete"
        return 0
    fi

    # Step 1: Transfer image (unless update-only)
    if [[ "$UPDATE_ONLY" != true ]]; then
        if [[ "$DRY_RUN" == true ]]; then
            print_info "[$node_name] Would transfer: $IMAGE_FILE -> ${node_user}@${node_ip}:${REMOTE_PATH}/"
        else
            print_info "[$node_name] Transferring image..."
            if ! run_scp "$node_ip" "$node_user" "$node_pass" "$IMAGE_FILE" "$REMOTE_PATH"; then
                print_error "[$node_name] Transfer failed"
                return 1
            fi
            print_success "[$node_name] Transfer complete"
        fi
    fi

    # Step 2: Update firmware (unless transfer-only)
    if [[ "$TRANSFER_ONLY" != true ]]; then
        local update_cmd
        if [[ -n "$CARD_UUID" ]]; then
            update_cmd="sudo nicctl update firmware -i $REMOTE_IMAGE_PATH -c $CARD_UUID"
        else
            update_cmd="sudo nicctl update firmware -i $REMOTE_IMAGE_PATH"
        fi

        if [[ "$DRY_RUN" == true ]]; then
            print_info "[$node_name] Would run: $update_cmd"
        else
            print_info "[$node_name] Updating firmware..."
            if ! run_ssh_command "$node_ip" "$node_user" "$node_pass" "$update_cmd"; then
                print_error "[$node_name] Firmware update failed"
                return 1
            fi
            print_success "[$node_name] Firmware update complete"
        fi

        # Step 3: Reset NIC (if requested)
        if [[ "$RESET_NIC" == true ]]; then
            local reset_cmd
            if [[ -n "$CARD_UUID" ]]; then
                reset_cmd="sudo nicctl reset card -c $CARD_UUID"
            else
                reset_cmd="sudo nicctl reset card --all"
            fi

            if [[ "$DRY_RUN" == true ]]; then
                print_info "[$node_name] Would run: $reset_cmd"
            else
                print_info "[$node_name] Resetting NIC..."
                if ! run_ssh_command "$node_ip" "$node_user" "$node_pass" "$reset_cmd"; then
                    print_error "[$node_name] NIC reset failed"
                    return 1
                fi
                print_success "[$node_name] NIC reset complete"
            fi
        fi
    fi

    print_success "[$node_name] Deployment complete"
    return 0
}

# Track success/failure
FAILED_NODES=()
SUCCESS_COUNT=0

if [[ "$PARALLEL" == true ]]; then
    echo "Deploying to nodes in parallel..."
    echo ""

    # Create temp directory for status files
    TEMP_DIR=$(mktemp -d)
    trap "rm -rf $TEMP_DIR" EXIT

    # Launch all deployments in parallel
    PIDS=()
    for ((i=0; i<NODE_COUNT; i++)); do
        NODE_NAME=$(get_node_field $i "name")

        # Skip if node doesn't match filter
        if ! should_process_node "$NODE_NAME"; then
            continue
        fi

        NODE_IP=$(get_node_field $i "ip")
        NODE_USER=$(get_node_field $i "username")
        NODE_PASS=$(get_node_field $i "password")

        (
            if deploy_to_node $i "$NODE_NAME" "$NODE_IP" "$NODE_USER" "$NODE_PASS"; then
                echo "success" > "$TEMP_DIR/$NODE_NAME.status"
            else
                echo "failed" > "$TEMP_DIR/$NODE_NAME.status"
            fi
        ) &
        PIDS+=($!)
    done

    # Wait for all deployments to complete
    for pid in "${PIDS[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    # Collect results
    for ((i=0; i<NODE_COUNT; i++)); do
        NODE_NAME=$(get_node_field $i "name")

        # Skip if node doesn't match filter
        if ! should_process_node "$NODE_NAME"; then
            continue
        fi

        if [[ -f "$TEMP_DIR/$NODE_NAME.status" && "$(cat "$TEMP_DIR/$NODE_NAME.status")" == "success" ]]; then
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        else
            FAILED_NODES+=("$NODE_NAME")
        fi
    done
else
    echo "Deploying to nodes sequentially..."
    echo ""

    for ((i=0; i<NODE_COUNT; i++)); do
        NODE_NAME=$(get_node_field $i "name")

        # Skip if node doesn't match filter
        if ! should_process_node "$NODE_NAME"; then
            continue
        fi

        NODE_IP=$(get_node_field $i "ip")
        NODE_USER=$(get_node_field $i "username")
        NODE_PASS=$(get_node_field $i "password")

        if deploy_to_node $i "$NODE_NAME" "$NODE_IP" "$NODE_USER" "$NODE_PASS"; then
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        else
            FAILED_NODES+=("$NODE_NAME")
        fi
        echo ""
    done
fi

# Summary
echo "========================================"
echo "Deployment Summary"
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
        print_success "All deployments completed successfully"
    fi
fi
