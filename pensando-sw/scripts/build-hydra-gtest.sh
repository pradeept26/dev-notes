#!/bin/bash
#
# Automated Hydra GTest Build - Vulcano ASIC
# Handles complete setup: tmux, submodules, docker, assets, build
#
# Usage:
#   ./build-hydra-gtest.sh [--clean] [--skip-submod] [--skip-assets] [--clean-docker]
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
    echo "Builds: Hydra GTest binaries for simulation testing (15-30 min)"
    exit 0
fi

# Build configuration
BUILD_NAME="gtest"
BUILD_CMD="make -f Makefile.ainic rudra-vulcano-hydra-gtest"
OUTPUT_FILE="/sw/nic/rudra/build/hydra/x86_64/sim/rudra/vulcano/bin/hydra_gtest"
DESCRIPTION="Vulcano hydra gtest"
BUILD_TIME="This may take 15-30 minutes..."
MAX_WAIT=120  # 2 hours

COMPLETION_MSG="GTest Build Complete!

Next steps:
  1. Attach to tmux: tmux attach -t pensando-sw
  2. Run tests (inside Docker at /sw/nic):

     cd /sw/nic
     DMA_MODE=uxdma ASIC=vulcano P4_PROGRAM=hydra \\
       GTEST_BINARY=/sw/nic/rudra/build/hydra/x86_64/sim/rudra/vulcano/bin/hydra_gtest \\
       GTEST_FILTER='resp_rx.invalid_path_id_nak' \\
       PROFILE=qemu LOG_FILE=hydra_gtest.log \\
       rudra/test/tools/run_ionic_gtest.sh

  See: ~/dev-notes/pensando-sw/testing/GTEST-QUICKREF.md for more commands"

# Run the automated build
run_automated_build "$BUILD_NAME" "$BUILD_CMD" "$OUTPUT_FILE" "$DESCRIPTION" "$BUILD_TIME" "$MAX_WAIT" "$COMPLETION_MSG"
