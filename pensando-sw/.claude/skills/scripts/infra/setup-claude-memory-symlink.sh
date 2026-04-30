#!/bin/bash
# Setup Claude memory symlink to use git-synced version
# Run this on each machine after pulling dev-notes

set -e

MEMORY_DIR="$HOME/dev-notes/pensando-sw/claude-memory"
CLAUDE_PROJECT_DIR="$HOME/.claude/projects/-ws-pradeept-ws-usr-src-github-com-pensando-sw"

# Check if dev-notes exists
if [ ! -d "$HOME/dev-notes" ]; then
    echo "ERROR: ~/dev-notes not found. Please clone dev-notes repo first."
    exit 1
fi

# Pull latest dev-notes
echo "Pulling latest dev-notes..."
cd ~/dev-notes
git pull

# Check if claude-memory exists in dev-notes
if [ ! -d "$MEMORY_DIR" ]; then
    echo "ERROR: claude-memory not found in dev-notes. Did you pull latest?"
    exit 1
fi

# Create Claude project directory if it doesn't exist
mkdir -p "$CLAUDE_PROJECT_DIR"

# Remove old memory directory if it exists
if [ -e "$CLAUDE_PROJECT_DIR/memory" ]; then
    if [ -L "$CLAUDE_PROJECT_DIR/memory" ]; then
        echo "Symlink already exists, removing..."
    else
        echo "Backing up existing memory directory..."
        mv "$CLAUDE_PROJECT_DIR/memory" "$CLAUDE_PROJECT_DIR/memory.bak.$(date +%Y%m%d_%H%M%S)"
    fi
    rm -rf "$CLAUDE_PROJECT_DIR/memory"
fi

# Create symlink
ln -s "$MEMORY_DIR" "$CLAUDE_PROJECT_DIR/memory"

echo "✅ Claude memory symlink created successfully!"
echo "   Memory location: $MEMORY_DIR"
echo "   Symlink: $CLAUDE_PROJECT_DIR/memory"
echo ""
echo "To sync memory across machines:"
echo "  1. cd ~/dev-notes && git pull"
echo "  2. Changes automatically reflect in Claude sessions"
