#!/bin/bash
# Auto-sync dev-notes/pensando-sw working data to git.
#
# Covers:
#   - pensando-sw/claude-memory/   (auto-memory; symlinked from ~/.claude/projects/.../memory)
#   - pensando-sw/.claude/skills/  (project-level Claude skills, including symlinked ones)
#   - pensando-sw/scripts/         (helper scripts)
#   - pensando-sw/skills/          (legacy/shared skill copies)
#
# Designed to be run:
#   - Manually after a non-trivial memory/skills change
#   - Automatically from a Claude Stop hook (silent when no changes)
#
# Exits 0 on success or no-op; non-zero only on actual git failure.

set -e

DEV_NOTES_DIR="$HOME/dev-notes"
SYNC_PATHS=(
  "pensando-sw/claude-memory"
  "pensando-sw/.claude/skills"
  "pensando-sw/scripts"
  "pensando-sw/skills"
)
QUIET=0
[[ "${1:-}" == "--quiet" ]] && QUIET=1

log() { [[ "$QUIET" == "1" ]] || echo "$@"; }

[[ -d "$DEV_NOTES_DIR/.git" ]] || { log "❌ $DEV_NOTES_DIR is not a git repo"; exit 1; }
cd "$DEV_NOTES_DIR"

# Detect changes (modified, staged, or untracked) under any of the SYNC_PATHS.
HAS_CHANGES=0
for p in "${SYNC_PATHS[@]}"; do
  [[ -e "$p" ]] || continue
  if ! git diff --quiet -- "$p" 2>/dev/null \
     || ! git diff --cached --quiet -- "$p" 2>/dev/null \
     || [[ -n "$(git ls-files --others --exclude-standard -- "$p")" ]]; then
    HAS_CHANGES=1
    break
  fi
done

if [[ "$HAS_CHANGES" == "0" ]]; then
  log "ℹ️  No dev-notes changes to sync"
  exit 0
fi

log "📝 Syncing dev-notes changes to git..."

# Stage each path that exists. -A picks up modifications and untracked files,
# while respecting .gitignore.
for p in "${SYNC_PATHS[@]}"; do
  [[ -e "$p" ]] && git add -A -- "$p"
done

# Bail if staging produced nothing (e.g. all changes were gitignored).
if git diff --cached --quiet; then
  log "ℹ️  All detected changes were gitignored — nothing to commit"
  exit 0
fi

TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
HOSTNAME=$(hostname)

# Summarize what's in this commit for the message body.
SUMMARY=$(git diff --cached --stat | tail -1 | sed 's/^ *//')

git commit -m "Auto-sync dev-notes from $HOSTNAME at $TIMESTAMP" \
           -m "$SUMMARY" \
           -m "Updated by Claude Code Stop hook (sync-claude-memory.sh)" >/dev/null

if git push >/dev/null 2>&1; then
  log "✅ Synced and pushed to remote"
else
  log "⚠️  Committed locally but push failed (network? auth?) — run 'cd $DEV_NOTES_DIR && git push' to retry"
  exit 0
fi
