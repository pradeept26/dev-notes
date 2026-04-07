#!/bin/bash
#
# Automated Hydra DOL Build - Vulcano ASIC
# Handles complete setup: tmux, submodules, docker, assets, x86 package build
#
# Usage:
#   ./build-hydra-dol.sh [--clean] [--skip-submod] [--skip-assets] [--clean-docker]
#

set -e

# Source common library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/build-common.sh"

# Parse arguments
if ! parse_common_args "$@"; then
    echo "Usage: $0 [--clean] [--skip-submod] [--skip-assets] [--clean-docker]"
    echo ""
    echo "Options:"
    echo "  --clean         Run make clean before build"
    echo "  --skip-submod   Skip submodule update"
    echo "  --skip-assets   Skip pull-assets"
    echo "  --clean-docker  Clean up old Docker containers (default: skip)"
    echo ""
    echo "Builds: x86 simulation package for DOL testing (15-25 min)"
    exit 0
fi

# Build configuration
BUILD_NAME="dol"
BUILD_CMD="make -C nic PIPELINE=rudra P4_PROGRAM=hydra ARCH=x86_64 ASIC=vulcano package"
OUTPUT_FILE="/sw/nic/build/x86_64/sim/rudra/vulcano/bin/pds_core_app"
DESCRIPTION="x86 package for DOL testing"
BUILD_TIME="This may take 15-25 minutes..."
MAX_WAIT=60  # 1 hour

COMPLETION_MSG="DOL Build Complete!

Binaries ready at: /sw/nic/build/x86_64/sim/rudra/vulcano/bin/

Run DOL tests (inside Docker at /sw/nic):
  cd /sw/nic
  PIPELINE=rudra ASIC=vulcano P4_PROGRAM=hydra PCIEMGR_IF=1 DMA_MODE=uxdma PROFILE=qemu \\
    rudra/test/tools/dol/rundol.sh \\
    --pipeline rudra --topo rdma_hydra --feature rdma_hydra --sub rdma_write --nohntap

Available tests: rdma_write, rdma_read, rdma_send, rdma_atomic

See: ~/dev-notes/pensando-sw/testing/DOL-QUICKREF.md"

# Run the automated build
run_automated_build "$BUILD_NAME" "$BUILD_CMD" "$OUTPUT_FILE" "$DESCRIPTION" "$BUILD_TIME" "$MAX_WAIT" "$COMPLETION_MSG"
