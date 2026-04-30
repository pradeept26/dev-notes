---
name: full-build
description: >
  Unified build skill for all ASIC/pipeline/target combinations.
  Always runs in background with log file. Use for gtest, dol, hw/fw,
  sim builds across vulcano/salina ASICs and hydra/pulsar pipelines.
  Triggers: "full build", "build vulcano", "build salina", "build firmware",
  "build gtest", "build dol", "build hw".
triggers:
  - full build
  - full-build
  - build vulcano
  - build salina
  - build firmware
  - build gtest for
  - build dol for
  - build hw for
---

# Full Build Skill

Unified build that:
1. Finds the running Docker container
2. Optionally cleans
3. Runs the correct make target in background
4. Redirects output to a log file

## Input

The user's arguments are: `$ARGUMENTS`

Parse:
- **ASIC** (required): `vulcano` or `salina`
- **Pipeline** (required): `hydra` or `pulsar`
- **Target** (required): `gtest`, `dol`, `hw`, `fw`, `sim`, `sw-emu`
- **Options:**
  - `--clean` — clean before build

If arguments are missing, ask the user. Default to `vulcano hydra` if ASIC/pipeline not specified.

## Build Target Mapping

### Vulcano
| Target | Make Command |
|--------|-------------|
| `gtest` | `make -f Makefile.build build-rudra-vulcano-hydra-gtest` |
| `dol` / `sw-emu` | `make -f Makefile.build build-rudra-vulcano-hydra-sw-emu` |
| `hw` / `fw` | `make -f Makefile.build build-rudra-vulcano-hydra-ainic-fw` |
| `sim` | `make -f Makefile.build build-rudra-vulcano-hydra-sim` |

### Salina
| Target | Make Command |
|--------|-------------|
| `gtest` / `sim` | `make -f Makefile.build build-rudra-salina-hydra-x86-dol` |
| `dol` / `sw-emu` | `make -f Makefile.build build-rudra-salina-hydra-x86-dol` |
| `hw` / `fw` | `make -f Makefile.build build-rudra-salina-hydra-ainic-bundle` |
| `a35-fw` | `make PIPELINE=rudra P4_PROGRAM=hydra rudra-salina-ainic-a35-fw` |

**Note:** Replace `hydra` with the pipeline name if using `pulsar`.

## Workflow

### Phase 1: Find Docker Container

```bash
CONTAINER_ID=$(docker ps --format '{{.ID}}' --filter ancestor=pensando/nic | head -1)
```

If no container found, tell the user to run `/setup` first and stop.

### Phase 2: Clean (if --clean)

```bash
docker exec -w /sw "$CONTAINER_ID" make -f Makefile.ainic clean
```

For Salina:
```bash
docker exec -w /sw "$CONTAINER_ID" rm -rf /sw/nic/build /sw/nic/rudra/build /sw/nic/conf/gen /sw/platform/rtos-sw/build
```

### Phase 3: Build (always background)

Construct the make command from the target mapping above, then run:

```bash
LOG_FILE="/tmp/build-<asic>-<pipeline>-<target>.log"

nohup docker exec -u $(whoami) -w /sw "$CONTAINER_ID" \
  <MAKE_COMMAND> \
  > "$LOG_FILE" 2>&1 &

echo "Build PID: $!"
```

Example for vulcano hydra gtest:
```bash
nohup docker exec -u $(whoami) -w /sw "$CONTAINER_ID" \
  make -f Makefile.build build-rudra-vulcano-hydra-gtest \
  > /tmp/build-vulcano-hydra-gtest.log 2>&1 &
```

### Phase 4: Report

Report to the user:
- Build target and make command
- Log file path
- How to check progress: `tail -20 <LOG_FILE>`
- How to check if done: `grep -q 'make\[1\]: Leaving' <LOG_FILE> && echo DONE || echo RUNNING`

## Checking Build Status

To check if a build is still running:
```bash
# Check if the nohup process is still alive
ps aux | grep "make.*build-rudra" | grep -v grep

# Tail the log
tail -20 /tmp/build-<asic>-<pipeline>-<target>.log

# Check for completion (success or failure)
tail -5 /tmp/build-<asic>-<pipeline>-<target>.log
```

## Examples

```
/full-build vulcano hydra gtest
/full-build vulcano hydra hw --clean
/full-build salina hydra fw
/full-build vulcano pulsar dol
```
