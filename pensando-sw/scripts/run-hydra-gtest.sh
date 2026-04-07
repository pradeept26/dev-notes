#!/bin/bash
#
# Hydra GTest Runner - Vulcano ASIC
# Automates building and running hydra gtests in Docker
#
# Usage:
#   ./run-hydra-gtest.sh build              # Build gtests only
#   ./run-hydra-gtest.sh test <filter>      # Run tests with filter
#   ./run-hydra-gtest.sh all                # Build and run all tests
#
# Examples:
#   ./run-hydra-gtest.sh test resp_rx.invalid_path_id_nak
#   ./run-hydra-gtest.sh test 'resp_rx.*'
#   ./run-hydra-gtest.sh test '-*scale*'
#

set -e

REPO_DIR="/ws/pradeept/ws/usr/src/github.com/pensando/sw"
TMUX_SESSION="pensando-sw"
ASIC="vulcano"
P4_PROGRAM="hydra"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_usage() {
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  build              Build hydra gtests"
    echo "  test <filter>      Run tests with Google Test filter"
    echo "  all                Build and run all tests (excluding scale)"
    echo "  clean              Clean build artifacts"
    echo "  status             Check build and environment status"
    echo ""
    echo "Examples:"
    echo "  $0 build"
    echo "  $0 test resp_rx.invalid_path_id_nak"
    echo "  $0 test 'resp_rx.*'"
    echo "  $0 all"
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

build_gtest() {
    if ! check_docker; then
        echo "Please run this command inside Docker"
        echo "Run: cd $REPO_DIR/nic && make docker/shell"
        exit 1
    fi

    echo -e "${YELLOW}Building hydra gtests for Vulcano...${NC}"
    cd /sw

    # Clean up old containers first
    docker ps -a | grep "$(whoami)_" | awk '{print $1}' | xargs -r docker stop 2>/dev/null || true
    docker ps -a | grep "$(whoami)_" | awk '{print $1}' | xargs -r docker rm 2>/dev/null || true

    echo "Running: make -f Makefile.build build-rudra-vulcano-hydra-gtest"
    make -f Makefile.build build-rudra-vulcano-hydra-gtest

    if [ -f /sw/build_vulcano_hydra_gtest.tar.gz ]; then
        echo -e "${GREEN}✓ Build successful: /sw/build_vulcano_hydra_gtest.tar.gz${NC}"
        ls -lh /sw/build_vulcano_hydra_gtest.tar.gz
    else
        echo -e "${RED}✗ Build failed${NC}"
        exit 1
    fi
}

run_test() {
    if ! check_docker; then
        echo "Please run this command inside Docker"
        exit 1
    fi

    local FILTER="${1:--*scale*}"
    local LOG_FILE="hydra_gtest_$(date +%Y%m%d_%H%M%S).log"

    # Check if gtest binary exists
    if [ ! -f /sw/nic/rudra/build/hydra/x86_64/sim/rudra/vulcano/bin/hydra_gtest ]; then
        echo -e "${RED}✗ Gtest binary not found. Please run 'build' first.${NC}"
        exit 1
    fi

    echo -e "${YELLOW}Running tests with filter: ${FILTER}${NC}"
    echo "Log file: $LOG_FILE"

    cd /sw/nic
    DMA_MODE=uxdma ASIC=vulcano P4_PROGRAM=hydra \
        GTEST_BINARY=/sw/nic/rudra/build/hydra/x86_64/sim/rudra/vulcano/bin/hydra_gtest \
        GTEST_FILTER="${FILTER}" \
        PROFILE=qemu \
        LOG_FILE="$LOG_FILE" \
        rudra/test/tools/run_ionic_gtest.sh

    echo -e "${GREEN}✓ Test run complete. Check $LOG_FILE for results${NC}"
}

clean_build() {
    if ! check_docker; then
        echo "Please run this command inside Docker"
        exit 1
    fi

    echo -e "${YELLOW}Cleaning build artifacts...${NC}"
    cd /sw
    rm -f /sw/build_vulcano_hydra_gtest.tar.gz
    rm -rf /sw/nic/rudra/build/hydra/x86_64/sim/rudra/vulcano/
    echo -e "${GREEN}✓ Clean complete${NC}"
}

check_status() {
    echo "Environment Status:"
    echo "=================="

    if check_docker; then
        echo ""
        if [ -f /sw/build_vulcano_hydra_gtest.tar.gz ]; then
            echo -e "${GREEN}✓ Build tarball exists${NC}"
            ls -lh /sw/build_vulcano_hydra_gtest.tar.gz
        else
            echo -e "${YELLOW}○ Build tarball not found${NC}"
        fi

        if [ -f /sw/nic/rudra/build/hydra/x86_64/sim/rudra/vulcano/bin/hydra_gtest ]; then
            echo -e "${GREEN}✓ Gtest binary exists${NC}"
        else
            echo -e "${YELLOW}○ Gtest binary not found${NC}"
        fi
    fi
}

# Main command handling
case "${1:-}" in
    build)
        build_gtest
        ;;
    test)
        if [ -z "${2:-}" ]; then
            echo "Error: test filter required"
            echo "Example: $0 test resp_rx.invalid_path_id_nak"
            exit 1
        fi
        run_test "$2"
        ;;
    all)
        build_gtest
        run_test "-*scale*"
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
