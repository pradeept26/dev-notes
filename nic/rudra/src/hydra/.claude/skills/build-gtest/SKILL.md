---
name: build-gtest
description: Build Hydra Google Test suite
triggers:
  - build gtest
  - build tests
  - build hydra gtest
  - build unit tests
---

# Build GTest Skill

Build the Hydra Google Test binary for unit testing.

## Usage Examples

- "build hydra gtest"
- "build the unit tests"
- "build gtest for vulcano"

## Script

Run via `quiet-run.sh` (see the `build` skill for rationale).

```bash
.claude/skills/scripts/lib/quiet-run.sh build-gtest \
  .claude/skills/scripts/build/build.sh vulcano hydra gtest
```

## Steps

1. Run build script with gtest platform
2. Report build success and binary location

## Output

- **Vulcano GTest binary**: `~/ws/sw/nic/rudra/build/hydra/x86_64/sim/rudra/vulcano/bin/hydra_gtest`
- **Vulcano AQ GTest binary**: `~/ws/sw/nic/rudra/build/hydra/x86_64/sim/rudra/vulcano/bin/hydra_gtest_aq`
- **Salina GTest binary**: `~/ws/sw/nic/rudra/build/hydra/x86_64/sim/rudra/salina/bin/hydra_gtest`
- **Salina AQ GTest binary**: `~/ws/sw/nic/rudra/build/hydra/x86_64/sim/rudra/salina/bin/hydra_gtest_aq`

(Salina binaries are produced by `build.sh salina hydra sim`, which now invokes
`make -C nic ... package` to cover both the model and the gtest targets — there
is no `rudra-salina-hydra-gtest` Makefile target like there is for vulcano.)

## Running Tests

The two ASICs use different runner scripts — match what CI does:

### Vulcano (`run_ionic_gtest.sh`, PROFILE=qemu)

CI command at `devops/jobs/level1/rudra/vulcano/test/hydra/sim/.job.yml`:

```bash
cd /sw/nic
DMA_MODE=uxdma ASIC=vulcano P4_PROGRAM=hydra \
  GTEST_BINARY=/sw/nic/rudra/build/hydra/x86_64/sim/rudra/vulcano/bin/hydra_gtest_aq \
  GTEST_FILTER='-*scale*' PROFILE=qemu LOG_FILE=hydra_gtest.log \
  rudra/test/tools/run_ionic_gtest.sh
```

Confirmed to produce 48/48 PASS on `hydra_gtest_aq` and 96/96 PASS on
`hydra_gtest` (excluding scale tests).

### Salina (`run_gtests.sh`, no PROFILE)

CI command at `devops/jobs/level1/rudra/salina/test/hydra/sim/.job.yml`:

```bash
cd /sw/nic
DMA_MODE=uxdma ASIC=salina /sw/nic/rudra/test/tools/run_gtests.sh \
    --p4_program hydra \
    --bin /sw/nic/rudra/build/hydra/x86_64/sim/rudra/salina/bin/hydra_gtest_aq \
    --gtest_filter=-*scale*
```

**Local-only workaround** (path mismatch between local build and what CI's
build tarball provides): `setup_env_sim.sh` symlinks `nic/conf/rudra/p4_asm`
to `nic/build/hydra/x86_64/sim/rudra/salina/bin/p4asm`, but our local build
puts `p4asm` under `nic/rudra/build/hydra/...`. Create a compatibility link
once per fresh container:

```bash
docker exec <cid> ln -sfn /sw/nic/rudra/build/hydra /sw/nic/build/hydra
```

## Notes

- GTest requires simulation environment (model + QEMU/zephyr + firmware)
- Takes several minutes to initialize before tests run
