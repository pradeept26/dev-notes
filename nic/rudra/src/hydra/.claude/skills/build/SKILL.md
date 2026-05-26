---
name: build
description: Build AINIC firmware for Hydra or Pulsar
triggers:
  - build firmware
  - build hydra
  - build pulsar
  - build vulcano
  - build hw
  - build sim
---

# Build Firmware Skill

Build AINIC firmware for different ASICs, P4 programs, and platforms.

## Usage Examples

- "build hydra for hardware"
- "build vulcano hydra hw"
- "clean build hydra"
- "build pulsar sim"
- "build hydra gtest"

## Parameters

| Parameter | Options | Default |
|-----------|---------|---------|
| asic | vulcano, salina | vulcano |
| p4_program | hydra, pulsar | hydra |
| platform | hw, sim, sw-emu, emu, gtest, host-tools, nicctl, dbg-tools | hw |
| clean | --clean, --clean-only | (none) |

## Script

Run via `quiet-run.sh` so the multi-thousand-line `make` output is
logged to `/tmp/claude-skills/build-*.log` instead of dumped into the
conversation. The wrapper prints the tail (more on failure) and the
log path; Read the log file if you need to inspect a specific failure.

```bash
.claude/skills/scripts/lib/quiet-run.sh build \
  .claude/skills/scripts/build/build.sh <asic> <p4_program> [platform] [options]
```

## Steps

1. Parse user request to identify asic, p4_program, platform
2. If user wants clean build, add `--clean` flag
3. Run the build script (it auto-detects Docker container)
4. Report build success/failure and output location

## Build Output Locations

- **Hardware**: `~/ws/sw/nic/rudra/build/{p4_program}/aarch64/hw/rudra/{asic}/`
- **Sim/emu**: `~/ws/sw/nic/rudra/build/{p4_program}/x86_64/{platform}/rudra/{asic}/`
- **Salina sim** (model + `zephyr.exe` for DOL):
  - `/sw/nic/build/x86_64/sim/rudra/salina/` (model artifacts: `sal_model.bin`, etc.)
  - `/sw/platform/rtos-sw/build/zephyr/zephyr.exe`
- **Firmware tarball**: `~/ws/sw/ainic_fw_{asic}.tar`

## Salina sim build target

Salina sim runs the underlying steps of `build-zephyr-salina-{p4_program}-sim`
(asset pulls + `sal_model.bin`/`model_sim_cli.bin` + `build-rtos-salina_sim-ainic`)
but skips both `tar`/`du` packaging steps from `Makefile.build` (those tarballs are
only consumed by CI `.job.yml` files). `zephyr.exe` is required by DOL when
`PROFILE=zephyr`.

## Notes

- Script auto-detects Docker container - don't manually find container ID
- If multiple containers exist, script will prompt for selection
  - **IMPORTANT**: The script will NOT automatically select the latest container
  - Different containers may have different build states or dependencies
  - You must explicitly choose via container ID argument or $HYDRA_CONTAINER env var
- First build requires `pull-assets` to be run
