#!/bin/bash
#
# Hydra DOL Runner - Vulcano ASIC
# Works from outside or inside Docker for build/all; test/status/clean require Docker.
#
# Usage:
#   ./run-hydra-dol.sh build              # Build sw-emu package (x86 + Zephyr fw)
#   ./run-hydra-dol.sh test <sub>         # Run specific DOL test (inside Docker)
#   ./run-hydra-dol.sh all                # Build and run rdma_write test
#   ./run-hydra-dol.sh clean              # Clean build artifacts (inside Docker)
#   ./run-hydra-dol.sh status             # Check environment status
#   ./run-hydra-dol.sh docker             # Enter Docker shell
#
# Flags (can appear anywhere):
#   --clean          Clean DOL artifacts before building
#   --clean-docker   Remove old Docker containers first
#   --skip-submod    Skip git submodule update (outside Docker only)
#   --skip-assets    Skip make pull-assets (outside Docker only)
#
# Examples:
#   ./run-hydra-dol.sh build --clean
#   ./run-hydra-dol.sh all --clean --clean-docker
#   ./run-hydra-dol.sh test rdma_write
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-/ws/pradeept/ws/usr/src/github.com/pensando/sw}"
TMUX_SESSION="pensando-sw"

# DOL run defaults
TOPO="rdma_hydra"
FEATURE="rdma_hydra"
NOHNTAP_FLAG="--nohntap"

# Flags
DO_CLEAN=false
CLEAN_DOCKER=false
SKIP_SUBMOD=false
SKIP_ASSETS=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_usage() {
    echo "Usage: $0 <command> [flags]"
    echo ""
    echo "Commands:"
    echo "  build              Build sw-emu package (x86 + Zephyr RISCV fw)"
    echo "  test <sub>         Run specific DOL test (inside Docker)"
    echo "  all                Build and run rdma_write test"
    echo "  clean              Clean DOL build artifacts (inside Docker)"
    echo "  status             Check build and environment status"
    echo "  docker             Enter Docker shell"
    echo ""
    echo "Flags:"
    echo "  --clean            Clean DOL artifacts before building"
    echo "  --clean-docker     Remove old Docker containers first"
    echo "  --skip-submod      Skip git submodule update"
    echo "  --skip-assets      Skip make pull-assets"
    echo ""
    echo "Available tests:"
    echo "  rdma_write, rdma_read, rdma_send, rdma_atomic"
    echo ""
    echo "Examples:"
    echo "  $0 build --clean"
    echo "  $0 all --clean --clean-docker"
    echo "  $0 test rdma_write"
    echo ""
    echo "See: ~/dev-notes/pensando-sw/testing/DOL-QUICKREF.md"
}

parse_flags() {
    for arg in "$@"; do
        case $arg in
            --clean)       DO_CLEAN=true ;;
            --clean-docker) CLEAN_DOCKER=true ;;
            --skip-submod) SKIP_SUBMOD=true ;;
            --skip-assets) SKIP_ASSETS=true ;;
        esac
    done
}

in_docker() {
    [ -f /.dockerenv ]
}

require_docker() {
    if ! in_docker; then
        echo -e "${RED}✗ This command must be run inside Docker${NC}"
        echo "Run: cd $REPO_DIR/nic && make docker/shell"
        exit 1
    fi
}

do_clean_artifacts() {
    echo -e "${YELLOW}Cleaning DOL build artifacts...${NC}"
    rm -rf /sw/nic/build/x86_64/sim/rudra/vulcano/
    rm -rf /sw/nic/rudra/build/hydra/riscv/sim/rudra/vulcano/
    rm -f /sw/zephyr_vulcano_sw_emu.tar.gz
    echo -e "${GREEN}✓ Clean complete${NC}"
}

# Build from inside Docker (direct)
build_inside_docker() {
    if [ "$DO_CLEAN" = true ]; then
        do_clean_artifacts
    fi

    echo -e "${YELLOW}Building Vulcano hydra sw-emu (x86 + Zephyr fw)...${NC}"
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

# Build from outside Docker (via tmux + build-common.sh)
build_outside_docker() {
    source "$SCRIPT_DIR/build-common.sh"

    # Pass our flags into build-common's globals
    SKIP_SUBMOD=$SKIP_SUBMOD
    SKIP_ASSETS=$SKIP_ASSETS
    CLEAN_DOCKER=false  # already handled before this call

    # Bake --clean into the build command so it runs inside Docker
    local BUILD_CMD
    if [ "$DO_CLEAN" = true ]; then
        BUILD_CMD="rm -rf /sw/nic/build/x86_64/sim/rudra/vulcano/ /sw/nic/rudra/build/hydra/riscv/sim/rudra/vulcano/ /sw/zephyr_vulcano_sw_emu.tar.gz 2>/dev/null || true; make -f Makefile.build build-rudra-vulcano-hydra-sw-emu"
    else
        BUILD_CMD="make -f Makefile.build build-rudra-vulcano-hydra-sw-emu"
    fi

    local COMPLETION_MSG="DOL Build Complete!

Run DOL tests (inside Docker at /sw/nic):
  cd /sw/nic
  PIPELINE=rudra ASIC=vulcano P4_PROGRAM=hydra PCIEMGR_IF=1 DMA_MODE=uxdma PROFILE=qemu \\\\
    rudra/test/tools/dol/rundol.sh \\\\
    --pipeline rudra --topo rdma_hydra --feature rdma_hydra --sub rdma_write --nohntap

Or use: ~/dev-notes/pensando-sw/scripts/run-hydra-dol.sh test rdma_write
See: ~/dev-notes/pensando-sw/testing/DOL-QUICKREF.md"

    run_automated_build \
        "dol" \
        "$BUILD_CMD" \
        "/sw/nic/build/x86_64/sim/rudra/vulcano/bin/pds_core_app" \
        "Vulcano hydra sw-emu (x86 + Zephyr fw)" \
        "This may take 30-60 minutes..." \
        "120" \
        "$COMPLETION_MSG"
}

build_dol() {
    if in_docker; then
        build_inside_docker
    else
        build_outside_docker
    fi
}

run_test() {
    require_docker
    local SUB="${1:-rdma_write}"

    if [ ! -f /sw/nic/build/x86_64/sim/rudra/vulcano/bin/pds_core_app ]; then
        echo -e "${RED}✗ DOL binaries not found. Run '$0 build' first.${NC}"
        exit 1
    fi

    echo -e "${YELLOW}Running DOL test: $SUB${NC}"
    echo "  Topology: $TOPO  |  Feature: $FEATURE  |  Sub: $SUB"
    echo ""

    cd /sw/nic
    PIPELINE=rudra ASIC=vulcano P4_PROGRAM=hydra PCIEMGR_IF=1 DMA_MODE=uxdma PROFILE=qemu \
        rudra/test/tools/dol/rundol.sh \
        --pipeline rudra --topo "$TOPO" --feature "$FEATURE" --sub "$SUB" \
        $NOHNTAP_FLAG

    local EXIT_CODE=$?
    if [ $EXIT_CODE -eq 0 ]; then
        echo -e "${GREEN}✓ DOL test '$SUB' PASSED${NC}"
    else
        echo -e "${RED}✗ DOL test '$SUB' FAILED (exit: $EXIT_CODE)${NC}"
        echo "Logs: /sw/nic/model.log  /var/log/pensando/pds-core-app.log  /var/log/pensando/dp-app.log"
    fi
    return $EXIT_CODE
}

check_status() {
    echo "DOL Environment Status:"
    echo "======================="
    if ! in_docker; then
        echo -e "${YELLOW}(Not in Docker — showing host-side info only)${NC}"
        echo ""
    fi

    echo "Build artifacts:"
    for binary in pds_core_app pds_dp_app vul_model; do
        local path="/sw/nic/build/x86_64/sim/rudra/vulcano/bin/$binary"
        if [ -f "$path" ]; then
            echo -e "${GREEN}✓ $binary$(ls -lh $path | awk '{print " ("$5", "$6" "$7")"}')${NC}"
        else
            echo -e "${YELLOW}○ $binary not found${NC}"
        fi
    done

    if in_docker; then
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
    fi
}

# --- Main ---

parse_flags "$@"

# --clean-docker always runs immediately, works outside Docker
if [ "$CLEAN_DOCKER" = true ]; then
    echo -e "${YELLOW}Cleaning up old Docker containers...${NC}"
    OLD=$(docker ps -a | grep "$(whoami)_" | awk '{print $1}' || true)
    if [ -n "$OLD" ]; then
        echo "$OLD" | xargs -r docker stop >/dev/null 2>&1 || true
        echo "$OLD" | xargs -r docker rm >/dev/null 2>&1 || true
        echo -e "${GREEN}✓ Old containers removed${NC}"
    else
        echo -e "${GREEN}✓ No old containers to clean${NC}"
    fi
fi

# Extract subcommand (first non-flag arg)
SUBCMD=""
for arg in "$@"; do
    case $arg in --*) ;; *) SUBCMD="$arg"; break ;; esac
done

case "${SUBCMD}" in
    build)
        build_dol
        ;;
    test)
        TEST_SUB=""; found=false
        for arg in "$@"; do
            case $arg in
                --*) ;;
                test) found=true ;;
                *) [ "$found" = true ] && { TEST_SUB="$arg"; break; } ;;
            esac
        done
        if [ -z "$TEST_SUB" ]; then
            echo "Error: test name required. Example: $0 test rdma_write"
            echo "Options: rdma_write, rdma_read, rdma_send, rdma_atomic"
            exit 1
        fi
        run_test "$TEST_SUB"
        ;;
    all)
        build_dol
        if in_docker; then
            run_test "rdma_write"
        else
            echo -e "${YELLOW}Build complete. Attach to Docker to run tests:${NC}"
            echo "  tmux attach -t $TMUX_SESSION"
            echo "  ~/dev-notes/pensando-sw/scripts/run-hydra-dol.sh test rdma_write"
        fi
        ;;
    clean)
        require_docker
        do_clean_artifacts
        ;;
    status)
        check_status
        ;;
    docker)
        echo -e "${YELLOW}Entering Docker...${NC}"
        cd "$REPO_DIR/nic"
        exec make docker/shell
        ;;
    "")
        print_usage
        ;;
    *)
        echo "Unknown command: $SUBCMD"
        print_usage
        exit 1
        ;;
esac
