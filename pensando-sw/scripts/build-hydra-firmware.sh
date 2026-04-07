#!/bin/bash
#
# Automated Hydra Firmware Build - Vulcano ASIC
# Handles complete setup: tmux, submodules, docker, assets, firmware build
#
# Usage:
#   ./build-hydra-firmware.sh [--clean] [--skip-submod] [--skip-assets] [--clean-docker] [--variant <name>]
#
# Options:
#   --clean         Run make clean before build
#   --skip-submod   Skip submodule update (if already updated)
#   --skip-assets   Skip pull-assets (if already pulled)
#   --clean-docker  Clean up old Docker containers before starting
#   --variant <m1|m2|m3|m4|m5|m6|gold>  Build specific module variant (default: full firmware)
#

set -e

REPO_DIR="/ws/pradeept/ws/usr/src/github.com/pensando/sw"
TMUX_SESSION="pensando-sw"
ASIC="vulcano"
P4_PROGRAM="hydra"
VARIANT=""

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
CLEAN_DOCKER=false

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
        --clean-docker)
            CLEAN_DOCKER=true
            ;;
        --variant)
            shift
            VARIANT="$1"
            if [[ ! "$VARIANT" =~ ^(m1|m2|m3|m4|m5|m6|gold)$ ]]; then
                echo "Error: Invalid variant '$VARIANT'. Must be one of: m1, m2, m3, m4, m5, m6, gold"
                exit 1
            fi
            ;;
        -h|--help)
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
            echo "  m5   - pciemgr, devmgr, nicmgr, qosmgr, linkmgr, hwmon"
            echo "  m6   - pciemgr, devmgr, linkmgr"
            echo "  gold - Gold firmware"
            exit 0
            ;;
        *)
            if [[ "$arg" != "$VARIANT" ]]; then
                echo "Unknown option: $arg"
                echo "Use --help for usage"
                exit 1
            fi
            ;;
    esac
    shift
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

# Step 3: Clean up old Docker containers (optional)
if [ "$CLEAN_DOCKER" = true ]; then
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
else
    log_info "Step 3: Skipping Docker container cleanup (use --clean-docker to enable)"
fi

# Step 4: Create build script for Docker
log_step "Step 4: Preparing Docker build commands..."

# Create script in repo dir (accessible as /sw inside Docker)
BUILD_SCRIPT="$REPO_DIR/hydra_fw_build_$$.sh"
cat > "$BUILD_SCRIPT" << 'EOFBUILD'
#!/bin/bash
set -e

SKIP_ASSETS="$1"
DO_CLEAN="$2"
VARIANT="$3"

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
    rm -f /sw/ainic_fw_vulcano.tar /sw/ainic_fw_vulcano.pldmfw
    echo -e "\033[0;32m✓ Clean complete\033[0m"
fi

# Build firmware
cd /sw

if [ -z "$VARIANT" ]; then
    echo -e "\033[0;34m▶ Building Vulcano hydra firmware (full)...\033[0m"
    echo -e "\033[1;33mℹ This may take 20-40 minutes...\033[0m"

    START_TIME=$(date +%s)
    make -f Makefile.ainic P4_PROGRAM=hydra rudra-vulcano-ainic-fw
    END_TIME=$(date +%s)

    TARGET_DESC="full firmware"
else
    echo -e "\033[0;34m▶ Building Vulcano hydra firmware variant: $VARIANT...\033[0m"
    echo -e "\033[1;33mℹ This may take 20-40 minutes...\033[0m"

    START_TIME=$(date +%s)
    if [ "$VARIANT" = "gold" ]; then
        make -f Makefile.ainic P4_PROGRAM=hydra rudra-vulcano-ainic-goldfw
    else
        make -f Makefile.ainic P4_PROGRAM=hydra rudra-vulcano-ainic-fw-$VARIANT
    fi
    END_TIME=$(date +%s)

    TARGET_DESC="variant $VARIANT"
fi

DURATION=$((END_TIME - START_TIME))
MINUTES=$((DURATION / 60))
SECONDS=$((DURATION % 60))

# Check for firmware output
if [ -f /sw/ainic_fw_vulcano.tar ]; then
    echo -e "\033[0;32m✓ Firmware build successful ($TARGET_DESC) in ${MINUTES}m ${SECONDS}s\033[0m"
    echo -e "\033[0;32m✓ Firmware package created\033[0m"
    ls -lh /sw/ainic_fw_vulcano.tar

    if [ -f /sw/ainic_fw_vulcano.pldmfw ]; then
        echo -e "\033[0;32m✓ PLDM firmware image created\033[0m"
        ls -lh /sw/ainic_fw_vulcano.pldmfw
    fi
else
    echo -e "\033[0;31m✗ Firmware build failed - ainic_fw_vulcano.tar not found\033[0m"
    exit 1
fi
EOFBUILD

chmod +x "$BUILD_SCRIPT"

# Step 5: Launch Docker (if needed) and run build
log_step "Step 5: Checking Docker status and building..."

# Create marker file to track build completion (in repo dir, accessible in Docker)
MARKER_FILE="$REPO_DIR/hydra_fw_build_complete_$$"
rm -f "$MARKER_FILE"

# Build script will be at /sw/hydra_fw_build_$$.sh inside Docker
DOCKER_BUILD_SCRIPT="/sw/$(basename $BUILD_SCRIPT)"
DOCKER_MARKER_FILE="/sw/$(basename $MARKER_FILE)"

# Check if Docker is already running in tmux session
log_info "Checking if Docker is already running in tmux session..."

# Send a command to check current directory
tmux send-keys -t "$TMUX_SESSION" "pwd > /tmp/check_docker_pwd_$$.txt" C-m
sleep 1

if [ -f /tmp/check_docker_pwd_$$.txt ]; then
    CURRENT_DIR=$(cat /tmp/check_docker_pwd_$$.txt)
    rm -f /tmp/check_docker_pwd_$$.txt

    if [[ "$CURRENT_DIR" == "/sw"* ]] || [[ "$CURRENT_DIR" == "/usr/src/github.com/pensando/sw"* ]]; then
        log_success "Docker already running, reusing existing container"
        ALREADY_IN_DOCKER=true
    else
        log_info "Not in Docker, launching container..."
        ALREADY_IN_DOCKER=false
    fi
else
    # Fallback: assume we need to launch Docker
    log_info "Cannot determine status, launching Docker..."
    ALREADY_IN_DOCKER=false
fi

# Launch Docker if needed
if [ "$ALREADY_IN_DOCKER" = false ]; then
    tmux send-keys -t "$TMUX_SESSION" "cd $REPO_DIR/nic" C-m
    tmux send-keys -t "$TMUX_SESSION" "make docker/shell" C-m
    sleep 3  # Give Docker time to start
    log_info "Docker container launched"
else
    log_info "Skipping Docker launch, already in container"
fi

# Execute build script
log_info "Executing firmware build inside Docker..."
log_info "This will take 20-40 minutes for a full build..."

# Run build in Docker via tmux
tmux send-keys -t "$TMUX_SESSION" "bash $DOCKER_BUILD_SCRIPT $SKIP_ASSETS $DO_CLEAN \"$VARIANT\" && touch $DOCKER_MARKER_FILE" C-m

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
    rm -f "$MARKER_FILE"
    rm -f "$BUILD_SCRIPT"

    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}Firmware Build Complete!${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "Output files:"
    echo "  - /sw/ainic_fw_vulcano.tar"
    echo "  - /sw/ainic_fw_vulcano.pldmfw"
    echo ""
    echo "Deploy to hardware:"
    echo "  1. Copy to host:"
    echo "     scp /sw/ainic_fw_vulcano.tar ubuntu@<HOST_IP>:/tmp/"
    echo ""
    echo "  2. Update firmware:"
    echo "     ssh ubuntu@<HOST_IP>"
    echo "     sudo nicctl update firmware -i /tmp/ainic_fw_vulcano.tar"
    echo ""
    echo "  3. Reset cards:"
    echo "     sudo nicctl reset card --all"
    echo ""
    echo "  4. Verify (wait 30s after reset):"
    echo "     sudo nicctl show card"
    echo "     sudo nicctl show version"
    echo ""
else
    log_error "Build timeout or interrupted"
    log_info "Check tmux session: tmux attach -t $TMUX_SESSION"
    rm -f "$BUILD_SCRIPT"
    exit 1
fi
