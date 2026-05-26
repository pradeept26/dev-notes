#!/bin/bash
#
# transfer_image.sh - Transfer firmware image to testbed hosts
#
# This script transfers a specified image file to all hosts in a testbed YAML file.
#

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARSER_SCRIPT="$SCRIPT_DIR/../testbed/parse_testbed.py"

# Default options
TESTBED_FILE=""
IMAGE_FILE=""
REMOTE_PATH="/tmp"
PARALLEL=false
DRY_RUN=false

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

Transfer a firmware image to all hosts in a testbed.

Arguments:
  testbed_yaml_file         Path to testbed YAML configuration file
  image_file                Path to the image file to transfer

Options:
  -d, --dest PATH           Remote destination path (default: /tmp)
  -p, --parallel            Transfer to all hosts in parallel
  -n, --dry-run             Show what would be done without actually transferring
  -h, --help                Show this help message

Examples:
  # Transfer image to all hosts in testbed (sequential)
  $(basename "$0") ~/ws/ainic-dev-tools/testbeds/prateek.yml ./firmware.tar

  # Transfer to custom remote path
  $(basename "$0") ~/ws/ainic-dev-tools/testbeds/prateek.yml ./firmware.tar -d /home/user/images

  # Transfer in parallel
  $(basename "$0") ~/ws/ainic-dev-tools/testbeds/prateek.yml ./firmware.tar -p

  # Dry run to see what would happen
  $(basename "$0") ~/ws/ainic-dev-tools/testbeds/prateek.yml ./firmware.tar -n

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

if [[ -z "$IMAGE_FILE" ]]; then
    print_error "Missing image file"
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

# Validate image file exists
if [[ ! -f "$IMAGE_FILE" ]]; then
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

# Get image file info
IMAGE_BASENAME=$(basename "$IMAGE_FILE")
IMAGE_SIZE=$(du -h "$IMAGE_FILE" | cut -f1)

echo "Testbed: $TESTBED_NAME"
echo "Nodes: $NODE_COUNT"
echo "Image: $IMAGE_BASENAME ($IMAGE_SIZE)"
echo "Remote path: $REMOTE_PATH"
echo ""

# Function to get node info by index
function get_node_field() {
    local idx=$1
    local field=$2
    echo "$TESTBED_JSON" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data['nodes'][$idx]['$field'])"
}

# Function to build SCP command
function build_scp_command() {
    local ip=$1
    local username=$2
    local password=$3
    local src_file=$4
    local dest_path=$5

    local remote_dest="${username}@${ip}:${dest_path}/"

    if [[ -n "$password" ]]; then
        # Use sshpass if password is provided
        if command -v sshpass &> /dev/null; then
            echo "sshpass -p '$password' scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null '$src_file' '$remote_dest'"
        else
            print_warning "sshpass not installed, password auth may fail for $ip"
            echo "scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null '$src_file' '$remote_dest'"
        fi
    else
        # Regular SCP (assumes key-based auth)
        echo "scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null '$src_file' '$remote_dest'"
    fi
}

# Function to transfer to a single node
function transfer_to_node() {
    local idx=$1
    local node_name=$2
    local node_ip=$3
    local node_user=$4
    local node_pass=$5

    local scp_cmd=$(build_scp_command "$node_ip" "$node_user" "$node_pass" "$IMAGE_FILE" "$REMOTE_PATH")

    if [[ "$DRY_RUN" == true ]]; then
        print_info "[$node_name] Would run: $scp_cmd"
        return 0
    fi

    print_info "[$node_name] Transferring to ${node_user}@${node_ip}:${REMOTE_PATH}/"

    if eval "$scp_cmd"; then
        print_success "[$node_name] Transfer complete"
        return 0
    else
        print_error "[$node_name] Transfer failed"
        return 1
    fi
}

# Track success/failure
FAILED_NODES=()
SUCCESS_COUNT=0

if [[ "$PARALLEL" == true ]]; then
    echo "Transferring in parallel..."
    echo ""

    # Create temp files for each transfer
    PIDS=()
    TEMP_FILES=()

    for ((i=0; i<NODE_COUNT; i++)); do
        NODE_NAME=$(get_node_field $i "name")
        NODE_IP=$(get_node_field $i "ip")
        NODE_USER=$(get_node_field $i "username")
        NODE_PASS=$(get_node_field $i "password")

        TEMP_FILE=$(mktemp)
        TEMP_FILES+=("$TEMP_FILE")

        (
            transfer_to_node $i "$NODE_NAME" "$NODE_IP" "$NODE_USER" "$NODE_PASS"
            echo $? > "$TEMP_FILE"
        ) &
        PIDS+=($!)
    done

    # Wait for all transfers to complete
    for ((i=0; i<${#PIDS[@]}; i++)); do
        wait ${PIDS[$i]} 2>/dev/null || true
        RESULT=$(cat "${TEMP_FILES[$i]}")
        rm -f "${TEMP_FILES[$i]}"

        NODE_NAME=$(get_node_field $i "name")
        if [[ "$RESULT" == "0" ]]; then
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        else
            FAILED_NODES+=("$NODE_NAME")
        fi
    done
else
    echo "Transferring sequentially..."
    echo ""

    for ((i=0; i<NODE_COUNT; i++)); do
        NODE_NAME=$(get_node_field $i "name")
        NODE_IP=$(get_node_field $i "ip")
        NODE_USER=$(get_node_field $i "username")
        NODE_PASS=$(get_node_field $i "password")

        if transfer_to_node $i "$NODE_NAME" "$NODE_IP" "$NODE_USER" "$NODE_PASS"; then
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        else
            FAILED_NODES+=("$NODE_NAME")
        fi
        echo ""
    done
fi

# Summary
echo "----------------------------------------"
echo "Transfer Summary"
echo "----------------------------------------"
echo "Total nodes: $NODE_COUNT"
echo "Successful: $SUCCESS_COUNT"
echo "Failed: ${#FAILED_NODES[@]}"

if [[ ${#FAILED_NODES[@]} -gt 0 ]]; then
    print_error "Failed nodes: ${FAILED_NODES[*]}"
    exit 1
else
    if [[ "$DRY_RUN" == true ]]; then
        print_success "Dry run complete - no actual transfers performed"
    else
        print_success "All transfers completed successfully"
    fi
fi
