#!/bin/bash
#
# Common Build Automation Library
# Shared functions for all Pensando SW build scripts
#
# Usage:
#   source ~/dev-notes/pensando-sw/scripts/build-common.sh
#   parse_common_args "$@"
#   run_automated_build "gtest" "make -f Makefile.ainic rudra-vulcano-hydra-gtest" "Build description"
#

# Configuration (can be overridden before sourcing)
# Auto-detect repo root from caller's CWD (works across machines/workspaces)
REPO_DIR="${REPO_DIR:-$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || echo '/ws/pradeept/ws/usr/src/github.com/pensando/sw')}"
TMUX_SESSION="${TMUX_SESSION:-pensando-sw}"
ASIC="${ASIC:-vulcano}"
P4_PROGRAM="${P4_PROGRAM:-hydra}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Global flags (set by parse_common_args)
DO_CLEAN=false
SKIP_SUBMOD=false
SKIP_ASSETS=false
CLEAN_DOCKER=false

# Logging functions
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

# Parse common command-line arguments
parse_common_args() {
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
            -h|--help)
                return 1  # Signal caller to show help
                ;;
            *)
                # Unknown args handled by caller
                ;;
        esac
    done
    return 0
}

# Check/create tmux session
setup_tmux_session() {
    log_step "Step 1: Checking tmux session..."
    if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        log_success "Tmux session '$TMUX_SESSION' exists"
    else
        log_info "Creating tmux session '$TMUX_SESSION'..."
        tmux new-session -d -s "$TMUX_SESSION" -c "$REPO_DIR"
        log_success "Tmux session created"
    fi
}

# Update git submodules
update_submodules() {
    if [ "$SKIP_SUBMOD" = false ]; then
        log_step "Step 2: Updating git submodules..."
        cd "$REPO_DIR"

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
}

# Clean up old Docker containers
cleanup_docker_containers() {
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
}

# Detect if Docker is already running in tmux session
detect_docker() {
    log_info "Checking if Docker is already running in tmux session..."

    # Send a command to check current directory (always use window 0)
    local CHECK_FILE="/tmp/check_docker_pwd_$$.txt"
    tmux send-keys -t "$TMUX_SESSION:0" "pwd > $CHECK_FILE" C-m
    sleep 1

    if [ -f "$CHECK_FILE" ]; then
        CURRENT_DIR=$(cat "$CHECK_FILE")
        rm -f "$CHECK_FILE"

        if [[ "$CURRENT_DIR" == "/sw"* ]] || [[ "$CURRENT_DIR" == "/usr/src/github.com/pensando/sw"* ]]; then
            log_success "Docker already running, reusing existing container"
            return 0  # Already in Docker
        fi
    fi

    log_info "Not in Docker, will launch container..."
    return 1  # Not in Docker
}

# Launch Docker container
launch_docker() {
    log_info "Launching Docker container..."
    tmux send-keys -t "$TMUX_SESSION:0" "cd $REPO_DIR/nic" C-m
    tmux send-keys -t "$TMUX_SESSION:0" "make docker/shell" C-m
    sleep 3  # Give Docker time to start
    log_info "Docker container launched"
}

# Generate build script for execution inside Docker
# Args: $1=build_name $2=build_command $3=output_check_file $4=output_description
generate_build_script() {
    local BUILD_NAME="$1"
    local BUILD_CMD="$2"
    local OUTPUT_FILE="$3"
    local OUTPUT_DESC="$4"
    local BUILD_TIME_MSG="${5:-This may take 15-30 minutes...}"

    local SCRIPT_FILE="$REPO_DIR/hydra_${BUILD_NAME}_build_$$.sh"

    cat > "$SCRIPT_FILE" << EOFBUILD
#!/bin/bash
set -e

SKIP_ASSETS="\$1"
DO_CLEAN="\$2"

echo -e "\033[0;34m▶ Inside Docker: \$(pwd)\033[0m"

# Pull assets
if [ "\$SKIP_ASSETS" = "false" ]; then
    echo -e "\033[0;34m▶ Pulling assets...\033[0m"
    cd /sw
    make pull-assets
    echo -e "\033[0;32m✓ Assets pulled\033[0m"
else
    echo -e "\033[1;33mℹ Skipping pull-assets (--skip-assets)\033[0m"
fi

# Clean if requested
if [ "\$DO_CLEAN" = "true" ]; then
    echo -e "\033[0;34m▶ Cleaning build artifacts...\033[0m"
    cd /sw
    make clean 2>/dev/null || true
    make -f Makefile.ainic clean 2>/dev/null || true
    echo -e "\033[0;32m✓ Clean complete\033[0m"
fi

# Build
echo -e "\033[0;34m▶ Building ${OUTPUT_DESC}...\033[0m"
echo -e "\033[1;33mℹ ${BUILD_TIME_MSG}\033[0m"
cd /sw

START_TIME=\$(date +%s)
${BUILD_CMD}
END_TIME=\$(date +%s)

DURATION=\$((END_TIME - START_TIME))
MINUTES=\$((DURATION / 60))
SECONDS=\$((DURATION % 60))

# Check output
if [ -f ${OUTPUT_FILE} ]; then
    echo -e "\033[0;32m✓ Build successful in \${MINUTES}m \${SECONDS}s\033[0m"
    ls -lh ${OUTPUT_FILE}
else
    echo -e "\033[0;31m✗ Build failed - output not found: ${OUTPUT_FILE}\033[0m"
    exit 1
fi
EOFBUILD

    chmod +x "$SCRIPT_FILE"
    echo "$SCRIPT_FILE"
}

# Execute build and monitor progress
# Args: $1=build_script_path $2=max_wait_minutes $3=completion_message
execute_and_monitor_build() {
    local BUILD_SCRIPT="$1"
    local MAX_WAIT="${2:-120}"  # Default 2 hours
    local COMPLETION_MSG="$3"

    local MARKER_FILE="$REPO_DIR/build_complete_$$.sh"
    rm -f "$MARKER_FILE"

    local DOCKER_BUILD_SCRIPT="/sw/$(basename $BUILD_SCRIPT)"
    local DOCKER_MARKER_FILE="/sw/$(basename $MARKER_FILE)"

    # Execute build script (always use window 0)
    log_info "Executing build inside Docker..."
    tmux send-keys -t "$TMUX_SESSION:0" "bash $DOCKER_BUILD_SCRIPT $SKIP_ASSETS $DO_CLEAN && touch $DOCKER_MARKER_FILE" C-m

    # Monitor
    log_info "Build running in tmux session '$TMUX_SESSION' (window 0)"
    log_info "You can attach to watch: tmux attach -t $TMUX_SESSION"

    echo ""
    echo -e "${YELLOW}Waiting for build to complete...${NC}"
    echo -e "${YELLOW}(This script will wait, or you can Ctrl+C and check later)${NC}"
    echo ""

    WAIT_COUNT=0
    while [ ! -f "$MARKER_FILE" ] && [ $WAIT_COUNT -lt $MAX_WAIT ]; do
        sleep 60
        WAIT_COUNT=$((WAIT_COUNT + 1))
        echo -e "${YELLOW}⏱  Build running... ${WAIT_COUNT} minutes elapsed${NC}"
    done

    # Cleanup
    rm -f "$MARKER_FILE"
    rm -f "$BUILD_SCRIPT"

    if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
        log_error "Build timeout"
        log_info "Check tmux session: tmux attach -t $TMUX_SESSION"
        return 1
    fi

    log_success "Build completed!"
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}${COMPLETION_MSG}${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# Main orchestration function
# Args: $1=build_name $2=build_command $3=output_file $4=description $5=build_time_msg $6=max_wait_min $7=completion_msg
run_automated_build() {
    local BUILD_NAME="$1"
    local BUILD_CMD="$2"
    local OUTPUT_FILE="$3"
    local DESC="$4"
    local BUILD_TIME_MSG="${5:-This may take 15-30 minutes...}"
    local MAX_WAIT="${6:-120}"
    local COMPLETION_MSG="$7"

    # Standard workflow
    setup_tmux_session
    update_submodules
    cleanup_docker_containers

    log_step "Step 4: Preparing Docker build commands..."
    BUILD_SCRIPT=$(generate_build_script "$BUILD_NAME" "$BUILD_CMD" "$OUTPUT_FILE" "$DESC" "$BUILD_TIME_MSG")

    log_step "Step 5: Checking Docker status and building..."
    if detect_docker; then
        log_info "Skipping Docker launch, already in container"
    else
        launch_docker
    fi

    execute_and_monitor_build "$BUILD_SCRIPT" "$MAX_WAIT" "$COMPLETION_MSG"
}
