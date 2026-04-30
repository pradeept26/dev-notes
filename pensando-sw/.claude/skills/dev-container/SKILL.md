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
cd /ws/pradeept/ws/usr/src/github.com/pensando/sw
git submodule update --init --recursive
```

This takes 1-2 minutes. Report when done.

### Phase 2: Stop and Remove ALL Existing Containers

Kill every `pensando/nic` container for this user — running or stopped:

```bash
docker ps -a --format '{{.ID}} {{.Image}}' | grep pensando/nic | awk '{print $1}' | xargs -r docker rm -f
```

This ensures a completely fresh Docker environment. No stale state from previous builds or branches.

### Phase 3: Launch Fresh Docker

```bash
cd /ws/pradeept/ws/usr/src/github.com/pensando/sw/nic && make docker/shell
```

This launches a new `pensando/nic` container with `/sw` mounted to the workspace.
It drops you into the container shell.

**IMPORTANT**: `make docker/shell` is interactive — it attaches to the container.
After it launches, exit the shell (Ctrl+D or `exit`) to return to the host.
The container stays running in the background.

### Phase 4: Pull Assets (Inside Docker)

Find the running container and pull assets:

```bash
CONTAINER_ID=$(docker ps --format '{{.ID}}' --filter ancestor=pensando/nic | head -1)
docker exec -u $(whoami) -w /sw "$CONTAINER_ID" make pull-assets
```

This downloads P4 compiler and other build dependencies. Takes 2-5 minutes.

### Phase 5: Report

Report:
- Container ID
- Submodule status
- Assets pulled
- Ready for `/full-build`
