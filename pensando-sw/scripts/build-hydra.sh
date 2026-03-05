#!/bin/bash
# Build Hydra Vulcano with tmux session management
# Usage: ./build-hydra.sh
#
# This script creates or attaches to a tmux session for running builds.
# One tmux session per workspace: 'pensando-sw'
#
# Tmux shortcuts:
#   Detach: Ctrl+b then d
#   Reattach: tmux attach -t pensando-sw

set -e

WORKSPACE_DIR="/ws/pradeept/ws/usr/src/github.com/pensando/sw"
TMUX_SESSION="pensando-sw"

# Check if tmux session exists
if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    echo "Tmux session '$TMUX_SESSION' already exists."
    echo "Attaching to existing session..."
    echo ""
    echo "To detach: Press Ctrl+b then d"
    echo ""
    sleep 1
    tmux attach-session -t "$TMUX_SESSION"
else
    echo "Creating new tmux session '$TMUX_SESSION'..."
    echo ""
    echo "After the session starts, run the build workflow:"
    echo "  1. cd /ws/pradeept/ws/usr/src/github.com/pensando/sw"
    echo "  2. git submodule update --init --recursive"
    echo "  3. docker ps -a | grep \"\$(whoami)_\" | awk '{print \$1}' | xargs -r docker stop | xargs -r docker rm"
    echo "  4. cd nic && make docker/shell"
    echo "  5. Inside docker: cd /sw && make pull-assets"
    echo "  6. Inside docker: make -f Makefile.build build-rudra-vulcano-hydra-x86-dol"
    echo ""
    echo "To detach from tmux: Press Ctrl+b then d"
    echo "To reattach later: tmux attach -t $TMUX_SESSION"
    echo ""
    sleep 2

    # Create tmux session at workspace directory
    tmux new-session -s "$TMUX_SESSION" -c "$WORKSPACE_DIR"
fi
