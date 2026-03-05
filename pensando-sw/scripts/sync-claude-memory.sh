#!/bin/bash
# Auto-sync Claude memory changes to git
# Called automatically by Claude after memory updates

set -e

MEMORY_DIR="$HOME/dev-notes/pensando-sw/claude-memory"
DEV_NOTES_DIR="$HOME/dev-notes"

cd "$DEV_NOTES_DIR"

# Check if there are any changes to memory files
if ! git diff --quiet pensando-sw/claude-memory/ 2>/dev/null && \
   ! git diff --cached --quiet pensando-sw/claude-memory/ 2>/dev/null; then

    echo "📝 Memory changes detected, syncing to git..."

    # Add memory files
    git add pensando-sw/claude-memory/

    # Create commit with timestamp
    TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
    HOSTNAME=$(hostname)

    git commit -m "Auto-sync Claude memory from $HOSTNAME at $TIMESTAMP" \
               -m "Updated by Claude Code automatic memory sync"

    # Push to remote
    git push

    echo "✅ Memory synced successfully!"
    echo "   Changes are now available on all machines after 'git pull'"
else
    echo "ℹ️  No memory changes to sync"
fi
