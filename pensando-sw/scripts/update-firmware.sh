#!/bin/bash
#
# Firmware Update Helper Script for Vulcano NICs
# Usage: ./update-firmware.sh <setup_name> <firmware_tar>
#
# Example:
#   ./update-firmware.sh smc1 /sw/ainic_fw_vulcano.tar
#   ./update-firmware.sh waco5 /path/to/ainic_fw_vulcano.tar
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="$SCRIPT_DIR/../hardware/vulcano/data"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

usage() {
    echo "Usage: $0 <setup_name> <firmware_tar>"
    echo ""
    echo "Available setups:"
    for yaml in "$DATA_DIR"/*.yml; do
        [ -f "$yaml" ] && basename "$yaml" .yml
    done
    echo ""
    echo "Example:"
    echo "  $0 smc1 /sw/ainic_fw_vulcano.tar"
    exit 1
}

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check arguments
if [ $# -ne 2 ]; then
    usage
fi

SETUP_NAME="$1"
FW_TAR="$2"
YAML_FILE="$DATA_DIR/${SETUP_NAME}.yml"

# Check if yq is installed
if ! command -v yq &> /dev/null; then
    log_error "yq is not installed. Install from: https://github.com/mikefarah/yq"
    exit 1
fi

# Check if YAML file exists
if [ ! -f "$YAML_FILE" ]; then
    log_error "Setup '$SETUP_NAME' not found. YAML file does not exist: $YAML_FILE"
    usage
fi

# Check if firmware tar exists
if [ ! -f "$FW_TAR" ]; then
    log_error "Firmware tar not found: $FW_TAR"
    exit 1
fi

# Extract info from YAML
HOST_IP=$(yq '.host.mgmt_ip' "$YAML_FILE")
SSH_USER=$(yq '.host.credentials.ssh_user' "$YAML_FILE")
NIC_COUNT=$(yq '.nics | length' "$YAML_FILE")

log_info "Setup: $SETUP_NAME"
log_info "Host: $SSH_USER@$HOST_IP"
log_info "NICs: $NIC_COUNT"
log_info "Firmware: $FW_TAR"
echo ""

# Confirm
read -p "Proceed with firmware update? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    log_warn "Aborted by user"
    exit 0
fi

# Step 1: Copy firmware to host
log_info "Step 1/4: Copying firmware to host..."
scp "$FW_TAR" "${SSH_USER}@${HOST_IP}:/tmp/ainic_fw_vulcano.tar"
if [ $? -eq 0 ]; then
    log_info "✓ Firmware copied successfully"
else
    log_error "Failed to copy firmware"
    exit 1
fi

# Step 2: Update firmware
log_info "Step 2/4: Updating firmware (this takes 3-5 minutes)..."
ssh "${SSH_USER}@${HOST_IP}" "sudo nicctl update firmware -i /tmp/ainic_fw_vulcano.tar"
if [ $? -eq 0 ]; then
    log_info "✓ Firmware updated to alternate partition"
else
    log_error "Firmware update failed"
    exit 1
fi

# Step 3: Reset cards
log_info "Step 3/4: Resetting all cards..."
ssh "${SSH_USER}@${HOST_IP}" "sudo nicctl reset card --all"
if [ $? -eq 0 ]; then
    log_info "✓ Cards reset initiated"
else
    log_error "Card reset failed"
    exit 1
fi

# Step 4: Verify
log_info "Step 4/4: Waiting for cards to come back up (30 seconds)..."
sleep 30

log_info "Verifying cards..."
CARD_COUNT=$(ssh "${SSH_USER}@${HOST_IP}" "sudo nicctl show card -j 2>/dev/null | jq '. | length' 2>/dev/null || echo 0")

if [ "$CARD_COUNT" -eq "$NIC_COUNT" ]; then
    log_info "✓ All $NIC_COUNT cards are up!"
    echo ""
    log_info "Firmware version:"
    ssh "${SSH_USER}@${HOST_IP}" "sudo nicctl show version"
else
    log_warn "Expected $NIC_COUNT cards, found $CARD_COUNT"
    log_warn "Some cards may not have come up. Check manually:"
    log_warn "  ssh ${SSH_USER}@${HOST_IP} 'sudo nicctl show card'"
    exit 1
fi

echo ""
log_info "Firmware update completed successfully!"
log_info "Next steps:"
log_info "  - Verify RDMA: ssh ${SSH_USER}@${HOST_IP} 'ibv_devices'"
log_info "  - Run tests if needed"
