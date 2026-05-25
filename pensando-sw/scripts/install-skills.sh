#!/bin/bash
# Install Claude Code skills from dev-notes to ~/.claude/skills/
# Run this on any machine after pulling dev-notes to set up skills.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILLS_SRC="$SCRIPT_DIR/../skills"
SKILLS_DST="$HOME/.claude/skills"

if [ ! -d "$SKILLS_SRC" ]; then
    echo "No skills directory found at $SKILLS_SRC"
    exit 1
fi

installed=0
for skill_dir in "$SKILLS_SRC"/*/; do
    skill_name=$(basename "$skill_dir")
    mkdir -p "$SKILLS_DST/$skill_name"
    cp -v "$skill_dir"/* "$SKILLS_DST/$skill_name/"
    installed=$((installed + 1))
done

echo "Installed $installed skill(s) to $SKILLS_DST"
