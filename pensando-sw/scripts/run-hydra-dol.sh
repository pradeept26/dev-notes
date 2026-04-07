#!/bin/bash
#
# Hydra DOL Runner - Vulcano ASIC
# Automates building and running hydra DOL tests in Docker
#
# Usage:
#   ./run-hydra-dol.sh build              # Build sw-emu package (x86 + Zephyr fw)
#   ./run-hydra-dol.sh test <sub>         # Run specific DOL test
#   ./run-hydra-dol.sh all                # Build and run rdma_write test
#   ./run-hydra-dol.sh clean              # Clean build artifacts
#   ./run-hydra-dol.sh status             # Check environment status
#   ./run-hydra-dol.sh docker             # Enter Docker shell
#
# Examples:
#   ./run-hydra-dol.sh test rdma_write
#   ./run-hydra-dol.sh test rdma_read
#   ./run-hydra-dol.sh test rdma_send
#   ./run-hydra-dol.sh test rdma_atomic
#

set -e

REPO_DIR="${REPO_DIR:-/ws/pradeept/ws/usr/src/github.com/pensando/sw}"
TMUX_SESSION="pensando-sw"
ASIC="vulcano"
P4_PROGRAM="hydra"

# DOL run defaults
TOPO="rdma_hydra"
FEATURE="rdma_hydra"
NOHNTAP_FLAG="--nohntap"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_usage() {
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  build              Build sw-emu package (x86 binaries + Zephyr RISCV firmware)"
    echo "  test <sub>         Run specific DOL test sub-feature"
    echo "  all                Build and run rdma_write test"
    echo "  clean              Clean DOL build artifacts"
    echo "  status             Check build and environment status"
    echo "  docker             Enter Docker shell"
    echo ""
    echo "Available tests (--sub):"
    echo "  rdma_write         RDMA write operations"
    echo "  rdma_read          RDMA read operations"
    echo "  rdma_send          RDMA send operations"
    echo "  rdma_atomic        RDMA atomic operations"
    echo ""
    echo "Examples:"
    echo "  $0 build"
    echo "  $0 test rdma_write"
    echo "  $0 test rdma_read"
    echo "  $0 all"
    echo ""
    echo "See: ~/dev-notes/pensando-sw/testing/DOL-QUICKREF.md"
}

check_docker() {
    if [ -f /.dockerenv ]; then
        echo -e "${GREEN}✓ Inside Docker${NC}"
        return 0
    else
        echo -e "${RED}✗ Not in Docker${NC}"
        return 1
    fi
}

enter_docker() {
    echo -e "${YELLOW}Entering Docker...${NC}"
    cd "$REPO_DIR/nic"
    exec make docker/shell
}

build_dol() {
    if ! check_docker; then
        echo "Please run this command inside Docker"
        echo "Run: cd $REPO_DIR/nic && make docker/shell"
        exit 1
    fi

    echo -e "${YELLOW}Building Vulcano hydra sw-emu package (x86 + Zephyr fw)...${NC}"
    echo "Running: make -f Makefile.build build-rudra-vulcano-hydra-sw-emu"
    echo "(This may take 30-60 minutes for a clean build)"
    cd /sw

    make -f Makefile.build build-rudra-vulcano-hydra-sw-emu

    if [ -f /sw/nic/build/x86_64/sim/rudra/vulcano/bin/pds_core_app ]; then
        echo -e "${GREEN}✓ Build successful${NC}"
        ls -lh /sw/nic/build/x86_64/sim/rudra/vulcano/bin/pds_core_app
        ls -lh /sw/nic/build/x86_64/sim/rudra/vulcano/bin/pds_dp_app 2>/dev/null || true
        ls -lh /sw/nic/build/x86_64/sim/rudra/vulcano/bin/vul_model 2>/dev/null || true
    else
        echo -e "${RED}✗ Build failed - pds_core_app not found${NC}"
        exit 1
    fi
}

run_test() {
    if ! check_docker; then
        echo "Please run this command inside Docker"
        exit 1
    fi

    local SUB="${1:-rdma_write}"

    if [ ! -f /sw/nic/build/x86_64/sim/rudra/vulcano/bin/pds_core_app ]; then
        echo -e "${RED}✗ DOL binaries not found. Run '$0 build' first.${NC}"
        exit 1
    fi

    echo -e "${YELLOW}Running DOL test: $SUB${NC}"
    echo "  Topology: $TOPO"
    echo "  Feature:  $FEATURE"
    echo "  Sub:      $SUB"
    echo "  HNTAP:    $([ -z "$NOHNTAP_FLAG" ] && echo 'enabled' || echo 'disabled')"
    echo ""

    cd /sw/nic

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
        --sub "$SUB" \
        $NOHNTAP_FLAG

    local EXIT_CODE=$?
    if [ $EXIT_CODE -eq 0 ]; then
        echo ""
        echo -e "${GREEN}✓ DOL test '$SUB' PASSED${NC}"
    else
        echo ""
        echo -e "${RED}✗ DOL test '$SUB' FAILED (exit code: $EXIT_CODE)${NC}"
        echo ""
        echo "Check logs:"
        echo "  tail -100 /sw/nic/model.log"
        echo "  tail -100 /var/log/pensando/pds-core-app.log"
        echo "  tail -100 /var/log/pensando/dp-app.log"
    fi
    return $EXIT_CODE
}

clean_build() {
    if ! check_docker; then
        echo "Please run this command inside Docker"
        exit 1
    fi

    echo -e "${YELLOW}Cleaning DOL build artifacts...${NC}"
    rm -rf /sw/nic/build/x86_64/sim/rudra/vulcano/
    rm -rf /sw/nic/rudra/build/hydra/riscv/sim/rudra/vulcano/
    rm -f /sw/zephyr_vulcano_sw_emu.tar.gz
    echo -e "${GREEN}✓ Clean complete${NC}"
}

check_status() {
    echo "DOL Environment Status:"
    echo "======================="

    if ! check_docker; then
        return 0
    fi

    echo ""
    echo "Build artifacts:"
    for binary in pds_core_app pds_dp_app vul_model; do
        local path="/sw/nic/build/x86_64/sim/rudra/vulcano/bin/$binary"
        if [ -f "$path" ]; then
            echo -e "${GREEN}✓ $binary$(ls -lh $path | awk '{print " ("$5", "$6" "$7")"}')${NC}"
        else
            echo -e "${YELLOW}○ $binary not found${NC}"
        fi
    done

    echo ""
    echo "Running processes:"
    for proc in vul_model pds_core_app pds_dp_app; do
        if pgrep -x "$proc" > /dev/null 2>&1; then
            echo -e "${GREEN}✓ $proc running${NC}"
        else
            echo -e "${YELLOW}○ $proc not running${NC}"
        fi
    done

    echo ""
    echo "Logs:"
    for log in /sw/nic/model.log /var/log/pensando/pds-core-app.log /var/log/pensando/dp-app.log /obfl/nicmgr.log; do
        if [ -f "$log" ]; then
            echo -e "${GREEN}✓ $log$(ls -lh $log | awk '{print " ("$5", "$6" "$7")"}')${NC}"
        else
            echo -e "${YELLOW}○ $log not found${NC}"
        fi
    done

    echo ""
    echo "Hugepages:"
    grep HugePages /proc/meminfo | head -4
}

# Main
case "${1:-}" in
    build)
        build_dol
        ;;
    test)
        if [ -z "${2:-}" ]; then
            echo "Error: test sub-feature required"
            echo "Example: $0 test rdma_write"
            echo "Options: rdma_write, rdma_read, rdma_send, rdma_atomic"
            exit 1
        fi
        run_test "$2"
        ;;
    all)
        build_dol
        run_test "rdma_write"
        ;;
    clean)
        clean_build
        ;;
    status)
        check_status
        ;;
    docker)
        enter_docker
        ;;
    "")
        print_usage
        ;;
    *)
        echo "Unknown command: $1"
        print_usage
        exit 1
        ;;
esac
