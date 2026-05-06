#!/bin/bash
# Setup all Claude Code skills (repo + private) on any machine
# Run from anywhere — auto-detects paths
#
# Usage: ~/dev-notes/pensando-sw/.claude/skills/scripts/infra/setup-skills.sh [repo-path]
#
# Prerequisites:
#   - ~/dev-notes cloned and up to date (git pull)
#   - pensando/sw repo cloned
#   - hydra-meta-roce-structure branch checked out (for repo skills)

set -e

REPO_ROOT="${1:-$(git -C "$(dirname "$0")/../../../../.." rev-parse --show-toplevel 2>/dev/null || echo "")}"

if [ -z "$REPO_ROOT" ]; then
    # Try common locations
    for d in /ws/*/ws/usr/src/github.com/pensando/sw; do
        if [ -d "$d/nic" ]; then
            REPO_ROOT="$d"
            break
        fi
    done
fi

if [ -z "$REPO_ROOT" ] || [ ! -d "$REPO_ROOT/nic" ]; then
    echo "ERROR: Cannot find pensando/sw repo. Pass the path as argument."
    echo "Usage: $0 /path/to/pensando/sw"
    exit 1
fi

SKILLS_DIR="$REPO_ROOT/.claude/skills"
PRIVATE_SKILLS="$HOME/dev-notes/pensando-sw/.claude/skills"
REPO_SKILLS="$REPO_ROOT/nic/rudra/src/hydra/.claude/skills"

echo "Repo root: $REPO_ROOT"
echo "Skills dir: $SKILLS_DIR"
echo "Private skills: $PRIVATE_SKILLS"
echo "Repo skills: $REPO_SKILLS"
echo ""

# Create .claude/skills if needed
mkdir -p "$SKILLS_DIR"

# 1. Symlink private skills from ~/dev-notes
if [ -d "$PRIVATE_SKILLS" ]; then
    echo "=== Private skills (from ~/dev-notes) ==="
    for skill in "$PRIVATE_SKILLS"/*/; do
        name=$(basename "$skill")
        [ "$name" = "scripts" ] && continue
        if [ -L "$SKILLS_DIR/$name" ]; then
            echo "  skip: $name (already linked)"
        else
            ln -sfn "$skill" "$SKILLS_DIR/$name"
            echo "  linked: $name"
        fi
    done
    echo ""
else
    echo "WARNING: ~/dev-notes/pensando-sw/.claude/skills not found"
    echo "  Run: cd ~/dev-notes && git pull"
    echo ""
fi

# 2. Symlink repo skills from hydra/.claude/skills
if [ -d "$REPO_SKILLS" ]; then
    echo "=== Repo skills (from hydra/.claude/skills) ==="
    for skill in "$REPO_SKILLS"/*/; do
        name=$(basename "$skill")
        [ "$name" = "scripts" ] && continue
        if [ -L "$SKILLS_DIR/$name" ]; then
            echo "  skip: $name (already linked)"
        else
            ln -sfn "$skill" "$SKILLS_DIR/$name"
            echo "  linked: $name"
        fi
    done
    echo ""
else
    echo "WARNING: Repo skills not found at $REPO_SKILLS"
    echo "  Make sure hydra-meta-roce-structure branch is checked out"
    echo ""
fi

# 3. Summary
echo "=== Installed skills ==="
ls -1 "$SKILLS_DIR" | grep -v scripts | while read name; do
    if [ -L "$SKILLS_DIR/$name" ]; then
        target=$(readlink "$SKILLS_DIR/$name")
        if [ -e "$SKILLS_DIR/$name/SKILL.md" ]; then
            echo "  ✓ $name"
        else
            echo "  ✗ $name (broken → $target)"
        fi
    fi
done

echo ""
echo "Done. Restart Claude Code to discover new skills."
