#!/bin/bash
# Connect to kenya-3668 and kenya-3636 in split-screen tmux session
# Created: 2026-04-07

SESSION_NAME="kenya-hosts"

# Check if session already exists
if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    echo "Session '$SESSION_NAME' already exists. Attaching..."
    tmux attach -t "$SESSION_NAME"
    exit 0
fi

# Create new session with kenya-3668 in first pane
tmux new-session -d -s "$SESSION_NAME" -n "kenya-pair" "ssh root@10.30.56.56"

# Split window horizontally and connect to kenya-3636
tmux split-window -h -t "$SESSION_NAME:0" "ssh root@10.30.56.55"

# Set even horizontal layout
tmux select-layout -t "$SESSION_NAME:0" even-horizontal

# Enable mouse support and synchronize panes option (can toggle with prefix+S)
tmux set-option -t "$SESSION_NAME" mouse on

# Add status bar info
tmux set-option -t "$SESSION_NAME" status-right "kenya-3668 (left) | kenya-3636 (right)"

echo "Created tmux session '$SESSION_NAME' with:"
echo "  Left pane:  kenya-3668 (10.30.56.56)"
echo "  Right pane: kenya-3636 (10.30.56.55)"
echo ""
echo "Attaching to session..."
echo ""
echo "Tip: Use Ctrl+b followed by:"
echo "  - Arrow keys to switch between panes"
echo "  - 'd' to detach"
echo "  - ':setw synchronize-panes on' to type in both panes simultaneously"
echo ""

# Attach to the session
tmux attach -t "$SESSION_NAME"
