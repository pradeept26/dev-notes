#!/bin/bash
#
# Recovery Procedure After Firmware Update
# Use this when cards don't come up after firmware update and reset
#
# Usage: ./recovery-after-fw-update.sh <setup_name>
# Example: ./recovery-after-fw-update.sh smc1
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

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

usage() {
    echo "Usage: $0 <setup_name>"
    echo ""
    echo "Recovery procedure when cards don't come up after firmware update."
    echo ""
    echo "Available setups:"
    for yaml in "$DATA_DIR"/*.yml; do
        [ -f "$yaml" ] && basename "$yaml" .yml
    done
    echo ""
    echo "Example:"
    echo "  $0 smc1"
    exit 1
}

if [ $# -ne 1 ]; then
    usage
fi

SETUP_NAME="$1"
YAML_FILE="$DATA_DIR/${SETUP_NAME}.yml"

# Check if yq is installed
if ! command -v yq &> /dev/null; then
    log_error "yq is not installed. Install from: https://github.com/mikefarah/yq"
    exit 1
fi

# Check if YAML file exists
if [ ! -f "$YAML_FILE" ]; then
    log_error "Setup '$SETUP_NAME' not found"
    usage
fi

# Extract info from YAML
HOST_IP=$(yq '.host.mgmt_ip' "$YAML_FILE")
SSH_USER=$(yq '.host.credentials.ssh_user' "$YAML_FILE")
BMC_IP=$(yq '.bmc.ip' "$YAML_FILE" 2>/dev/null || echo "")

log_info "╔════════════════════════════════════════════════════════════════╗"
log_info "║     Firmware Update Recovery Procedure                        ║"
log_info "╚════════════════════════════════════════════════════════════════╝"
log_info ""
log_info "Setup: $SETUP_NAME"
log_info "Host: $SSH_USER@$HOST_IP"
log_info "BMC: $BMC_IP"
echo ""

# Confirm
read -p "This will reboot the host. Continue? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    log_warn "Aborted by user"
    exit 0
fi

echo ""

# Step 1: Verify firmware version on Vulcano consoles
log_step "1/5: Checking firmware version on all Vulcano consoles..."
echo ""
"$SCRIPT_DIR/console-mgr.py" --setup "$SETUP_NAME" --console vulcano --all version
if [ $? -eq 0 ]; then
    log_info "✓ Firmware version check completed"
else
    log_warn "Failed to check some consoles (may be OK, continuing...)"
fi

echo ""
read -p "Press Enter to continue with SuC reboot..."

# Step 2: Reboot Vulcano via SuC
log_step "2/5: Rebooting all Vulcano NICs via SuC consoles..."
echo ""
"$SCRIPT_DIR/console-mgr.py" --setup "$SETUP_NAME" --console suc --all reboot
if [ $? -eq 0 ]; then
    log_info "✓ SuC reboot commands sent (kernel reboot)"
else
    log_error "Failed to send reboot to some SuC consoles"
    exit 1
fi

echo ""
log_info "Waiting 30 seconds for Vulcano NICs to reboot..."
sleep 30

# Step 3: Reboot host
log_step "3/5: Rebooting host system..."
ssh "${SSH_USER}@${HOST_IP}" 'sudo reboot' &
log_info "✓ Host reboot initiated"

# Step 4: Wait for host to come back
log_step "4/5: Waiting for host to come back up (2-3 minutes)..."
echo ""

# Wait and ping
sleep 60
for i in {1..12}; do
    if ping -c 1 -W 2 "$HOST_IP" &> /dev/null; then
        log_info "✓ Host is responding to ping"
        break
    fi
    echo -n "."
    sleep 10
done
echo ""

# Wait for SSH
log_info "Waiting for SSH to be available..."
for i in {1..12}; do
    if ssh -o ConnectTimeout=5 "${SSH_USER}@${HOST_IP}" 'true' &> /dev/null; then
        log_info "✓ SSH is available"
        break
    fi
    echo -n "."
    sleep 10
done
echo ""

# Step 5: Verify cards
log_step "5/5: Verifying all cards are up..."
echo ""

# Wait a bit more for drivers to load
sleep 20

CARD_OUTPUT=$(ssh "${SSH_USER}@${HOST_IP}" 'sudo nicctl show card 2>&1')
CARD_COUNT=$(echo "$CARD_OUTPUT" | grep -c "^ai" || echo 0)

echo "$CARD_OUTPUT"
echo ""

if [ "$CARD_COUNT" -eq 8 ]; then
    log_info "╔════════════════════════════════════════════════════════════════╗"
    log_info "║  ✓ SUCCESS! All 8 cards are up!                               ║"
    log_info "╚════════════════════════════════════════════════════════════════╝"
    echo ""
    log_info "Firmware version:"
    ssh "${SSH_USER}@${HOST_IP}" 'sudo nicctl show version'
    exit 0
else
    log_warn "╔════════════════════════════════════════════════════════════════╗"
    log_warn "║  WARNING: Only $CARD_COUNT/8 cards are up                          ║"
    log_warn "╚════════════════════════════════════════════════════════════════╝"
    echo ""
    log_warn "Manual investigation required:"
    log_warn "  ssh ${SSH_USER}@${HOST_IP}"
    log_warn "  sudo nicctl show card"
    log_warn "  sudo dmesg | grep -i pensando"
    log_warn "  sudo nicctl techsupport /tmp/debug.tar.gz"
    exit 1
fi
