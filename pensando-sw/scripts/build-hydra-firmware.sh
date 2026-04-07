#!/bin/bash
#
# Automated Hydra Firmware Build - Vulcano ASIC
# Handles complete setup: tmux, submodules, docker, assets, firmware build
#
# Usage:
#   ./build-hydra-firmware.sh [--clean] [--skip-submod] [--skip-assets] [--clean-docker] [--variant <name>]
#

set -e

# Source common library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/build-common.sh"

# Parse variant argument
VARIANT=""
for arg in "$@"; do
    case $arg in
        --variant)
            shift
            VARIANT="$1"
            if [[ ! "$VARIANT" =~ ^(m1|m2|m3|m4|m5|m6|gold)$ ]]; then
                echo "Error: Invalid variant '$VARIANT'. Must be one of: m1, m2, m3, m4, m5, m6, gold"
                exit 1
            fi
            shift
            ;;
    esac
done

# Parse common arguments
if ! parse_common_args "$@"; then
    echo "Usage: $0 [--clean] [--skip-submod] [--skip-assets] [--clean-docker] [--variant <name>]"
    echo ""
    echo "Options:"
    echo "  --clean         Run make clean before build"
    echo "  --skip-submod   Skip submodule update"
    echo "  --skip-assets   Skip pull-assets"
    echo "  --clean-docker  Clean up old Docker containers (default: skip)"
    echo "  --variant <m1|m2|m3|m4|m5|m6|gold>  Build module variant"
    echo ""
    echo "Module Variants:"
    echo "  m1   - pciemgr, devmgr"
    echo "  m2   - devmgr, nicmgr"
    echo "  m3   - pciemgr, devmgr, nicmgr"
    echo "  m4   - pciemgr, devmgr, nicmgr, qosmgr"
    echo "  m5   - pciemgr, devmgr, nicmgr, qosmgr, linkmgr, hwmon (recommended)"
    echo "  m6   - pciemgr, devmgr, linkmgr"
    echo "  gold - Gold firmware"
    echo ""
    echo "Builds: Hydra firmware for hardware deployment (20-40 min)"
    exit 0
fi

# Build configuration
BUILD_NAME="firmware"
if [ -z "$VARIANT" ]; then
    BUILD_CMD="make -f Makefile.ainic P4_PROGRAM=hydra rudra-vulcano-ainic-fw"
    DESCRIPTION="Vulcano hydra firmware (full)"
elif [ "$VARIANT" = "gold" ]; then
    BUILD_CMD="make -f Makefile.ainic P4_PROGRAM=hydra rudra-vulcano-ainic-goldfw"
    DESCRIPTION="Vulcano hydra firmware (gold)"
else
    BUILD_CMD="make -f Makefile.ainic P4_PROGRAM=hydra rudra-vulcano-ainic-fw-$VARIANT"
    DESCRIPTION="Vulcano hydra firmware (variant $VARIANT)"
fi

OUTPUT_FILE="/sw/ainic_fw_vulcano.tar"
BUILD_TIME="This may take 20-40 minutes..."
MAX_WAIT=120  # 2 hours

COMPLETION_MSG="Firmware Build Complete!

Output files:
  - /sw/ainic_fw_vulcano.tar
  - /sw/ainic_fw_vulcano.pldmfw

Deploy to hardware:
  1. Copy: scp /sw/ainic_fw_vulcano.tar ubuntu@<HOST_IP>:/tmp/
  2. Update: sudo nicctl update firmware -i /tmp/ainic_fw_vulcano.tar
  3. Reset: sudo nicctl reset card --all
  4. Verify: sudo nicctl show card && sudo nicctl show version

See: ~/dev-notes/pensando-sw/testing/FIRMWARE-QUICKREF.md"

# Run the automated build
run_automated_build "$BUILD_NAME" "$BUILD_CMD" "$OUTPUT_FILE" "$DESCRIPTION" "$BUILD_TIME" "$MAX_WAIT" "$COMPLETION_MSG"
