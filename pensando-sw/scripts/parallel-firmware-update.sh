#!/bin/bash
#
# Parallel Firmware Update Script
# Updates firmware on multiple setups simultaneously
#
# Usage: ./parallel-firmware-update.sh <firmware_tar> <setup1> <setup2> ...
# Example: ./parallel-firmware-update.sh /sw/ainic_fw_vulcano.tar smc1 smc2 gt1 gt4
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="$SCRIPT_DIR/../hardware/vulcano/data"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

usage() {
    echo "Usage: $0 <firmware_tar> <setup1> [setup2] [setup3] ..."
    echo ""
    echo "Updates firmware on multiple setups in parallel"
    echo ""
    echo "Available setups:"
    for yaml in "$DATA_DIR"/*.yml; do
        [ -f "$yaml" ] && echo "  - $(basename "$yaml" .yml)"
    done
    echo ""
    echo "Examples:"
    echo "  $0 /sw/ainic_fw_vulcano.tar smc1 smc2"
    echo "  $0 /sw/ainic_fw_vulcano.tar smc1 smc2 gt1 gt4"
    echo "  $0 /sw/ainic_fw_vulcano.tar smc1 smc2 gt1 gt4 waco5 waco6"
    exit 1
}

# Check if yq is installed
if ! command -v yq &> /dev/null; then
    log_error "yq is not installed. Install from: https://github.com/mikefarah/yq"
    exit 1
fi

# Check arguments
if [ $# -lt 2 ]; then
    usage
fi

FW_TAR="$1"
shift
SETUPS=("$@")

# Check firmware exists
if [ ! -f "$FW_TAR" ]; then
    log_error "Firmware not found: $FW_TAR"
    exit 1
fi

# Validate all setups exist
for setup in "${SETUPS[@]}"; do
    if [ ! -f "$DATA_DIR/${setup}.yml" ]; then
        log_error "Setup '$setup' not found. YAML file missing: $DATA_DIR/${setup}.yml"
        usage
    fi
done

log_info "╔════════════════════════════════════════════════════════════════╗"
log_info "║  Parallel Firmware Update                                     ║"
log_info "╚════════════════════════════════════════════════════════════════╝"
log_info ""
log_info "Firmware: $FW_TAR"
log_info "Setups: ${SETUPS[*]}"
log_info "Total: ${#SETUPS[@]} systems"
echo ""

# Confirm
read -p "Update firmware on all systems in parallel? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    log_warn "Aborted by user"
    exit 0
fi

echo ""

# Function to update single setup
update_single_setup() {
    local setup_name=$1
    local fw_tar=$2
    local log_file="/tmp/fw_update_${setup_name}_$$.log"

    {
        echo "[$setup_name] Starting firmware update..."

        # Get setup info
        local yaml_file="$DATA_DIR/${setup_name}.yml"
        local host_ip=$(yq '.host.mgmt_ip' "$yaml_file")
        local ssh_user=$(yq '.host.credentials.ssh_user' "$yaml_file")
        local ssh_pass=$(yq '.host.credentials.ssh_password' "$yaml_file")

        echo "[$setup_name] Host: $ssh_user@$host_ip"

        # Step 1: Copy firmware
        echo "[$setup_name] Copying firmware..."
        if ! sshpass -p "$ssh_pass" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            "$fw_tar" "${ssh_user}@${host_ip}:/tmp/ainic_fw_vulcano.tar" 2>&1; then
            echo "[$setup_name] ERROR: Failed to copy firmware"
            return 1
        fi

        # Step 2: Update firmware
        echo "[$setup_name] Updating firmware (3-5 min)..."
        if ! sshpass -p "$ssh_pass" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            "${ssh_user}@${host_ip}" 'sudo nicctl update firmware -i /tmp/ainic_fw_vulcano.tar' 2>&1; then
            echo "[$setup_name] ERROR: Firmware update failed"
            return 1
        fi

        # Step 3: Reset cards
        echo "[$setup_name] Resetting cards..."
        if ! sshpass -p "$ssh_pass" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            "${ssh_user}@${host_ip}" 'sudo nicctl reset card --all' 2>&1; then
            echo "[$setup_name] ERROR: Card reset failed"
            return 1
        fi

        # Step 4: Wait for cards
        echo "[$setup_name] Waiting for cards (30s)..."
        sleep 30

        # Step 5: Run init script (if available)
        local init_script=$(yq '.setup.init_script' "$yaml_file" 2>/dev/null)
        if [ "$init_script" != "null" ] && [ -n "$init_script" ]; then
            echo "[$setup_name] Running init script: $init_script"
            sshpass -p "$ssh_pass" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                "${ssh_user}@${host_ip}" "$init_script" 2>&1 || true
        fi

        # Step 6: Verify
        echo "[$setup_name] Verifying cards..."
        local card_output=$(sshpass -p "$ssh_pass" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            "${ssh_user}@${host_ip}" 'sudo nicctl show card 2>&1')
        local card_count=$(echo "$card_output" | grep -c "^[0-9a-f]" || echo 0)

        if [ "$card_count" -ge 8 ]; then
            echo "[$setup_name] ✓ SUCCESS: $card_count cards up"
            return 0
        else
            echo "[$setup_name] ! WARNING: Only $card_count/8 cards up"
            echo "$card_output"
            return 1
        fi

    } > "$log_file" 2>&1

    # Return status
    local status=$?
    cat "$log_file"
    rm -f "$log_file"
    return $status
}

# Create temporary directory for logs
TMP_DIR="/tmp/parallel_fw_update_$$"
mkdir -p "$TMP_DIR"

# Start all updates in parallel
declare -A PIDS
declare -A START_TIMES

log_step "Starting parallel firmware updates..."
echo ""

for setup in "${SETUPS[@]}"; do
    log_info "Launching update for $setup..."
    START_TIMES[$setup]=$(date +%s)
    update_single_setup "$setup" "$FW_TAR" > "$TMP_DIR/${setup}.log" 2>&1 &
    PIDS[$setup]=$!
    sleep 2  # Small delay to avoid SCP contention
done

echo ""
log_step "All updates launched in parallel"
log_info "Monitoring progress..."
echo ""

# Monitor progress
while true; do
    all_done=true
    for setup in "${SETUPS[@]}"; do
        pid=${PIDS[$setup]}
        if kill -0 $pid 2>/dev/null; then
            all_done=false
        fi
    done

    if $all_done; then
        break
    fi

    # Show status
    echo -ne "\r$(date '+%H:%M:%S') - Updates in progress..."
    sleep 5
done

echo ""
echo ""

# Collect results
log_step "Collecting results..."
echo ""

declare -A RESULTS
SUCCESS_COUNT=0
FAIL_COUNT=0

for setup in "${SETUPS[@]}"; do
    pid=${PIDS[$setup]}
    wait $pid
    exit_code=$?

    # Calculate duration
    end_time=$(date +%s)
    duration=$((end_time - START_TIMES[$setup]))

    if [ $exit_code -eq 0 ]; then
        RESULTS[$setup]="✓ SUCCESS (${duration}s)"
        ((SUCCESS_COUNT++))
        log_info "$setup: ✓ SUCCESS (${duration}s)"
    else
        RESULTS[$setup]="✗ FAILED (${duration}s)"
        ((FAIL_COUNT++))
        log_error "$setup: ✗ FAILED (${duration}s)"
    fi

    # Show log file location
    echo "  Log: $TMP_DIR/${setup}.log"
done

echo ""
log_info "╔════════════════════════════════════════════════════════════════╗"
log_info "║  Parallel Firmware Update Complete                            ║"
log_info "╚════════════════════════════════════════════════════════════════╝"
echo ""

# Summary table
echo "SUMMARY:"
echo "--------"
for setup in "${SETUPS[@]}"; do
    printf "%-10s : %s\n" "$setup" "${RESULTS[$setup]}"
done

echo ""
echo "Total: $SUCCESS_COUNT succeeded, $FAIL_COUNT failed out of ${#SETUPS[@]} systems"
echo ""

# Show failed logs
if [ $FAIL_COUNT -gt 0 ]; then
    log_warn "Failed updates - check logs:"
    for setup in "${SETUPS[@]}"; do
        if [[ "${RESULTS[$setup]}" == *"FAILED"* ]]; then
            echo "  cat $TMP_DIR/${setup}.log"
        fi
    done
    echo ""
fi

# Cleanup option
echo "Logs saved in: $TMP_DIR/"
read -p "Delete logs? (yes/no): " DELETE
if [ "$DELETE" == "yes" ]; then
    rm -rf "$TMP_DIR"
    log_info "Logs deleted"
else
    log_info "Logs preserved: $TMP_DIR/"
fi

# Exit with error if any failed
if [ $FAIL_COUNT -gt 0 ]; then
    exit 1
else
    exit 0
fi
