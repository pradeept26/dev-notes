---
name: dev-container
description: "One-time dev container setup: kill old Docker containers, launch fresh pensando/nic container, update submodules, pull assets. Use when switching branches, first time setup, or after pulling changes. Triggers: setup dev container, setup container, prep workspace, launch docker, fresh docker, new container."
---

# Workspace Setup Skill

One-time preparation for building. Run when:
- First time on a new branch
- After switching branches
- After pulling changes
- Docker container was cleaned up

## Input

The user's arguments are: `$ARGUMENTS`

No arguments required. All steps run in sequence.

## Workflow

### Phase 1: Submodule Update (Host)

Run on the host (NOT inside Docker):

```bash
cd $(git rev-parse --show-toplevel)
git submodule update --init --recursive
```

This takes 1-2 minutes. Report when done.

### Phase 2: Stop and Remove Existing Containers for This User

**IMPORTANT:** Each step must be a separate, simple Bash tool call — no pipe chains
or compound commands. This ensures they match permission rules and run without prompts.

**Step 1 — list containers to remove (matching this user AND this workspace):**

The workspace root is mounted as `/sw` inside the container. Only remove containers
that belong to the current user AND mount this specific workspace.

```bash
WS_ROOT=$(git rev-parse --show-toplevel)
docker ps -a --format '{{.Names}}' | grep "^$(whoami)_" | while read name; do
  src=$(docker inspect "$name" --format '{{range .Mounts}}{{if eq .Destination "/sw"}}{{.Source}}{{end}}{{end}}')
  if [ "$src" = "$WS_ROOT" ]; then
    echo "$name"
  fi
done
```

**Step 2 — for each container name returned, remove it:**
```bash
docker rm -f <CONTAINER_NAME>
```

If step 1 returns nothing, skip step 2 — no containers to clean up.
Only removes containers matching the user's naming pattern AND this workspace.
Does NOT touch other users' containers or the user's containers for other workspaces.

### Phase 3: Launch Fresh Docker

```bash
cd $(git rev-parse --show-toplevel)/nic && make docker/background-shell
```

This is the one command that requires `cd &&` — it must run from the `nic/` directory.
Uses `docker/background-shell` (not `docker/shell`) — launches the container
detached so it works without a TTY. Functionally identical to `docker/shell`
(same image, volumes, env, privileges) but compatible with Claude and automation.

The container name follows the pattern `username_YYYY-MM-DD_HH.MM.SS`.

### Phase 3.5: Fix Git Ownership (Inside Docker)

**MUST run immediately after launching the container.** The `/sw` mount is owned by
the host user but accessed as a different UID inside Docker. Without this fix,
Zephyr CMake builds fail because `git describe` returns empty output.

```bash
docker exec <CONTAINER_NAME> git config --global --add safe.directory /sw
```

### Phase 4: Pull Assets (Inside Docker)

First resolve the container name, then pull assets in background.

**Step 1 — resolve container name (matching this user AND this workspace):**
```bash
WS_ROOT=$(git rev-parse --show-toplevel)
docker ps --format '{{.Names}}' | grep "^$(whoami)_" | while read name; do
  src=$(docker inspect "$name" --format '{{range .Mounts}}{{if eq .Destination "/sw"}}{{.Source}}{{end}}{{end}}')
  if [ "$src" = "$WS_ROOT" ]; then
    echo "$name"
    break
  fi
done
```

**Step 2 — pull assets (use `run_in_background=true` on the Bash tool):**
```bash
docker exec <CONTAINER_NAME> bash -c 'cd /sw && make pull-assets'
```

**IMPORTANT:** Use the Bash tool's `run_in_background=true` parameter instead of
shell `&` with redirects. This keeps the command simple so it matches the
`Bash(docker exec *)` permission rule and avoids prompts. Each step must be a
simple command — no compound `&&` chains, no variable assignments in the same call.

Takes 2-5 minutes. Claude is notified automatically when it completes.

The `platform_ainic_vulcano_suc_zephyr` asset may fail due to wsctl issues —
this is non-critical and does not block gtest or firmware builds.

### Phase 5: Report

Report:
- Container ID
- Submodule status
- Assets pulled
- Ready for `/full-build`
