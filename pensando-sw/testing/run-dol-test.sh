#!/bin/bash
#
# Hydra DOL Test Runner - Use inside Docker
# Simple wrapper for running DOL tests with correct environment
#
# Usage (inside Docker at /sw/nic):
#   bash ~/dev-notes/pensando-sw/testing/run-dol-test.sh <test-name> [--nohntap] [--topo <topo>]
#
# Examples:
#   bash ~/dev-notes/pensando-sw/testing/run-dol-test.sh rdma_write
#   bash ~/dev-notes/pensando-sw/testing/run-dol-test.sh rdma_read --topo rdma_hydra
#
# IMPORTANT: This file is in dev-notes, copy it to /sw before using in Docker!
#

set -e

# Check if we're in Docker
if [[ ! "$(pwd)" =~ ^/sw || ! "$(pwd)" =~ pensando/sw ]]; then
    echo "Error: This script must be run inside Docker at /sw/nic"
    echo "Current directory: $(pwd)"
    exit 1
fi

# Check if binaries exist
if [ ! -f /sw/nic/build/x86_64/sim/rudra/vulcano/bin/pds_core_app ]; then
    echo "Error: DOL binaries not found"
    echo "Please build first: make -C nic PIPELINE=rudra P4_PROGRAM=hydra ARCH=x86_64 ASIC=vulcano package"
    exit 1
fi

# Parse arguments
TEST_NAME="${1:-rdma_write}"
TOPO="rdma_hydra"
FEATURE="rdma_hydra"
NOHNTAP_FLAG="--nohntap"

shift || true
for arg in "$@"; do
    case $arg in
        --topo)
            shift
            TOPO="$1"
            ;;
        --feature)
            shift
            FEATURE="$1"
            ;;
        --nohntap)
            NOHNTAP_FLAG="--nohntap"
            ;;
        --with-hntap)
            NOHNTAP_FLAG=""
            ;;
        -h|--help)
            echo "Usage: $0 <test-name> [--nohntap] [--topo <topo>] [--feature <feature>]"
            echo ""
            echo "Arguments:"
            echo "  test-name       Test to run (e.g., rdma_write, rdma_read, rdma_send)"
            echo ""
            echo "Options:"
            echo "  --topo <name>   Topology (default: rdma_hydra)"
            echo "  --feature <name> Feature (default: rdma_hydra)"
            echo "  --nohntap       Disable HNTAP (default)"
            echo "  --with-hntap    Enable HNTAP"
            echo ""
            echo "Common tests:"
            echo "  rdma_write  - RDMA write operations"
            echo "  rdma_read   - RDMA read operations"
            echo "  rdma_send   - RDMA send operations"
            echo "  rdma_atomic - RDMA atomic operations"
            exit 0
            ;;
        *)
            shift || true
            ;;
    esac
done

echo "▶ Running DOL test: $TEST_NAME"
echo "  Topology: $TOPO"
echo "  Feature: $FEATURE"
echo "  HNTAP: $([ -z "$NOHNTAP_FLAG" ] && echo 'enabled' || echo 'disabled')"
echo ""

cd /sw/nic

# Run DOL test
PIPELINE=rudra \
ASIC=vulcano \
P4_PROGRAM=hydra \
PCIEMGR_IF=1 \
DMA_MODE=uxdma \
PROFILE=qemu \
  rudra/test/tools/dol/rundol.sh \
  --pipeline rudra \
  --topo "$TOPO" \
  --feature "$FEATURE" \
  --sub "$TEST_NAME" \
  $NOHNTAP_FLAG

exit_code=$?

if [ $exit_code -eq 0 ]; then
    echo ""
    echo "✓ DOL test '$TEST_NAME' PASSED"
else
    echo ""
    echo "✗ DOL test '$TEST_NAME' FAILED (exit code: $exit_code)"
    echo ""
    echo "Check logs:"
    echo "  - /tmp/model.log"
    echo "  - /var/log/pensando/nicmgr.log"
fi

exit $exit_code
