#!/bin/bash
# quiet-run.sh — wrapper for noisy scripts.
#
# Runs a command with all output redirected to a log file under
# /tmp/claude-skills/. Prints the tail of the log (30 lines on
# success, 100 on failure) plus the log path and exit status.
# Pass-through exit code so callers can chain with && / ||.
#
# Usage:
#   quiet-run.sh <label> <command> [args...]
#
# Example:
#   quiet-run.sh pull-assets .claude/skills/scripts/build/pull-assets.sh vulcano hydra hw
#
# Tip: tail -f /tmp/claude-skills/<label>-*.log in another shell to watch live.

set -uo pipefail

if [ $# -lt 2 ]; then
    echo "Usage: $0 <label> <command> [args...]" >&2
    exit 2
fi

label="$1"
shift

logdir="/tmp/claude-skills.${UID}"
(umask 077 && mkdir -p "$logdir")
ts=$(date +%Y%m%d-%H%M%S)
logfile="$logdir/${label}-${ts}.log"

# Symlink "<label>-latest.log" to the most recent run for convenience.
ln -sfn "$logfile" "$logdir/${label}-latest.log"

# Run command with all output (stdout + stderr) to the log file.
"$@" > "$logfile" 2>&1
exit_code=$?

total_lines=$(wc -l < "$logfile" | tr -d ' ')

if [ "$exit_code" -eq 0 ]; then
    tail_lines=30
    status_msg="OK: $label succeeded"
else
    tail_lines=100
    status_msg="FAIL: $label exited $exit_code"
fi

echo "=== $status_msg ==="
echo "Log: $logfile ($total_lines lines)"

if [ "$total_lines" -le "$tail_lines" ]; then
    echo "--- full output ---"
    cat "$logfile"
else
    echo "--- last $tail_lines lines (full log at path above) ---"
    tail -n "$tail_lines" "$logfile"
fi

exit "$exit_code"
