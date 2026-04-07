#!/bin/bash
#
# Automated Hydra GTest Build - Vulcano ASIC
# Handles complete setup: tmux, submodules, docker, assets, build
#
# Usage:
#   ./build-hydra-gtest.sh [--clean] [--skip-submod] [--skip-assets]
#
# Options:
#   --clean         Run make clean before build
#   --skip-submod   Skip submodule update (if already updated)
#   --skip-assets   Skip pull-assets (if already pulled)
#

set -e

REPO_DIR="/ws/pradeept/ws/usr/src/github.com/pensando/sw"
TMUX_SESSION="pensando-sw"
ASIC="vulcano"
P4_PROGRAM="hydra"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Parse arguments
DO_CLEAN=false
SKIP_SUBMOD=false
SKIP_ASSETS=false

for arg in "$@"; do
    case $arg in
        --clean)
            DO_CLEAN=true
            ;;
        --skip-submod)
            SKIP_SUBMOD=true
            ;;
        --skip-assets)
            SKIP_ASSETS=true
            ;;
        -h|--help)
            echo "Usage: $0 [--clean] [--skip-submod] [--skip-assets]"
            echo ""
            echo "Options:"
            echo "  --clean         Run make clean before build"
            echo "  --skip-submod   Skip submodule update"
            echo "  --skip-assets   Skip pull-assets"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg"
            echo "Use --help for usage"
            exit 1
            ;;
    esac
done

log_step() {
    echo -e "${BLUE}▶ $1${NC}"
}

log_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

log_error() {
    echo -e "${RED}✗ $1${NC}"
}

log_info() {
    echo -e "${YELLOW}ℹ $1${NC}"
}

# Step 1: Check/Create tmux session
log_step "Step 1: Checking tmux session..."
if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    log_success "Tmux session '$TMUX_SESSION' exists"
else
    log_info "Creating tmux session '$TMUX_SESSION'..."
    tmux new-session -d -s "$TMUX_SESSION" -c "$REPO_DIR"
    log_success "Tmux session created"
fi

# Step 2: Update submodules (outside docker)
if [ "$SKIP_SUBMOD" = false ]; then
    log_step "Step 2: Updating git submodules..."
    cd "$REPO_DIR"

    # Check if submodules need updating
    if git submodule status | grep -q '^-'; then
        log_info "Submodules not initialized, running update..."
        git submodule update --init --recursive
        log_success "Submodules initialized"
    else
        log_info "Checking for submodule updates..."
        git submodule update --recursive
        log_success "Submodules updated"
    fi
else
    log_info "Step 2: Skipping submodule update (--skip-submod)"
fi

# Step 3: Clean up old Docker containers
log_step "Step 3: Cleaning up old Docker containers..."
OLD_CONTAINERS=$(docker ps -a | grep "$(whoami)_" | awk '{print $1}' || true)
if [ -n "$OLD_CONTAINERS" ]; then
    log_info "Removing old containers..."
    echo "$OLD_CONTAINERS" | xargs -r docker stop >/dev/null 2>&1 || true
    echo "$OLD_CONTAINERS" | xargs -r docker rm >/dev/null 2>&1 || true
    log_success "Old containers cleaned up"
else
    log_success "No old containers to clean"
fi

# Step 4: Create build script for Docker
log_step "Step 4: Preparing Docker build commands..."

# Create script in repo dir (mounted as /sw in Docker)
BUILD_SCRIPT="$REPO_DIR/hydra_gtest_build_$$.sh"
cat > "$BUILD_SCRIPT" << 'EOFBUILD'
#!/bin/bash
set -e

SKIP_ASSETS="$1"
DO_CLEAN="$2"

echo -e "\033[0;34m▶ Inside Docker: $(pwd)\033[0m"

# Pull assets
if [ "$SKIP_ASSETS" = "false" ]; then
    echo -e "\033[0;34m▶ Pulling assets...\033[0m"
    cd /sw
    make pull-assets
    echo -e "\033[0;32m✓ Assets pulled\033[0m"
else
    echo -e "\033[1;33mℹ Skipping pull-assets (--skip-assets)\033[0m"
fi

# Clean if requested
if [ "$DO_CLEAN" = "true" ]; then
    echo -e "\033[0;34m▶ Cleaning build artifacts...\033[0m"
    cd /sw
    make clean 2>/dev/null || true
    make -f Makefile.ainic clean 2>/dev/null || true
    rm -f /sw/build_vulcano_hydra_gtest.tar.gz
    echo -e "\033[0;32m✓ Clean complete\033[0m"
fi

# Build hydra gtest
echo -e "\033[0;34m▶ Building hydra gtest for Vulcano...\033[0m"
echo -e "\033[1;33mℹ This may take 15-30 minutes...\033[0m"
cd /sw

START_TIME=$(date +%s)

# Step 1: Build sw-emu
echo -e "\033[0;34m▶ Step 1: Building sw-emu...\033[0m"
make -f Makefile.ainic rudra-vulcano-hydra-sw-emu

# Step 2: Build gtest
echo -e "\033[0;34m▶ Step 2: Building gtest...\033[0m"
make -f Makefile.ainic rudra-vulcano-hydra-gtest

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
MINUTES=$((DURATION / 60))
SECONDS=$((DURATION % 60))

# Check for gtest binary (don't rely on tarball)
if [ -f /sw/nic/rudra/build/hydra/x86_64/sim/rudra/vulcano/bin/hydra_gtest ]; then
    echo -e "\033[0;32m✓ Build successful in ${MINUTES}m ${SECONDS}s\033[0m"
    echo -e "\033[0;32m✓ Gtest binary created\033[0m"
    ls -lh /sw/nic/rudra/build/hydra/x86_64/sim/rudra/vulcano/bin/hydra_gtest*
else
    echo -e "\033[0;31m✗ Build failed - gtest binary not found\033[0m"
    exit 1
fi
EOFBUILD

chmod +x "$BUILD_SCRIPT"

# Step 5: Launch Docker and run build
log_step "Step 5: Launching Docker and building..."
log_info "This will take 15-30 minutes for a full build..."

cd "$REPO_DIR/nic"

# Execute in tmux session
tmux send-keys -t "$TMUX_SESSION" "cd $REPO_DIR/nic" C-m
tmux send-keys -t "$TMUX_SESSION" "make docker/shell" C-m
sleep 3  # Give Docker time to start

# Copy build script into Docker and execute
log_info "Executing build inside Docker..."

# Create a marker file to track build completion (in repo dir, accessible in Docker)
MARKER_FILE="$REPO_DIR/hydra_gtest_build_complete_$$"
rm -f "$MARKER_FILE"

# Build script will be at /sw/hydra_gtest_build_$$.sh inside Docker
DOCKER_BUILD_SCRIPT="/sw/$(basename $BUILD_SCRIPT)"
DOCKER_MARKER_FILE="/sw/$(basename $MARKER_FILE)"

# Run build in Docker via tmux
tmux send-keys -t "$TMUX_SESSION" "bash $DOCKER_BUILD_SCRIPT $SKIP_ASSETS $DO_CLEAN && touch $DOCKER_MARKER_FILE" C-m

# Monitor build progress
log_info "Build running in tmux session '$TMUX_SESSION'"
log_info "You can attach to watch: tmux attach -t $TMUX_SESSION"
log_info "Or detach and come back later"

echo ""
echo -e "${YELLOW}Waiting for build to complete...${NC}"
echo -e "${YELLOW}(This script will wait, or you can Ctrl+C and check later)${NC}"
echo ""

# Wait for completion marker
WAIT_COUNT=0
MAX_WAIT=120  # 2 hours max (120 * 60 seconds)
while [ ! -f "$MARKER_FILE" ] && [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    sleep 60
    WAIT_COUNT=$((WAIT_COUNT + 1))
    ELAPSED=$((WAIT_COUNT))
    echo -e "${YELLOW}⏱  Build running... ${ELAPSED} minutes elapsed${NC}"
done

if [ -f "$MARKER_FILE" ]; then
    log_success "Build completed!"
    # Clean up temp files
    rm -f "$MARKER_FILE"
    rm -f "$BUILD_SCRIPT"

    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}Build Complete!${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "Next steps:"
    echo "  1. Attach to tmux: tmux attach -t $TMUX_SESSION"
    echo "  2. Run tests:"
    echo ""
    echo "     # Inside Docker at /sw/nic:"
    echo "     ~/dev-notes/pensando-sw/scripts/run-hydra-gtest.sh test resp_rx.invalid_path_id_nak"
    echo ""
    echo "  Or use the manual command:"
    echo "     DMA_MODE=uxdma ASIC=vulcano P4_PROGRAM=hydra \\"
    echo "       GTEST_BINARY=/sw/nic/rudra/build/hydra/x86_64/sim/rudra/vulcano/bin/hydra_gtest \\"
    echo "       GTEST_FILTER='resp_rx.invalid_path_id_nak' \\"
    echo "       PROFILE=qemu LOG_FILE=hydra_gtest.log \\"
    echo "       rudra/test/tools/run_ionic_gtest.sh"
    echo ""
else
    log_error "Build timeout or interrupted"
    log_info "Check tmux session: tmux attach -t $TMUX_SESSION"
    rm -f "$BUILD_SCRIPT"
    exit 1
fi
