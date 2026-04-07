---
name: Hydra/Vulcano DOL Test Setup
description: Build target, run command, and artifacts for hydra/vulcano DOL tests in sw-1 repo (source of truth: devops/jobs/level1/rudra/vulcano/test/hydra/sim/.job.yml)
type: project
---

## Build target (inside docker at /sw)

```bash
make -f Makefile.build build-rudra-vulcano-hydra-sw-emu
```

Defined in `Makefile.build:1548`. Depends on `build-vulcano-model` (builds vul_model).
Key artifacts produced:
- `nic/build/x86_64/sim/rudra/vulcano/bin/` — x86 binaries (vul_model, pds_core_app, pds_dp_app)
- `nic/rudra/build/hydra/riscv/sim/rudra/vulcano/` — RISCV Zephyr firmware
- `nic/conf/gen/` — generated configs

**Why:** There is NO `build-rudra-vulcano-hydra-x86-dol` target. The correct target for hydra/vulcano sim DOL is `build-rudra-vulcano-hydra-sw-emu` (builds Zephyr RISCV firmware + x86 model together).

## Run DOL tests (inside docker, from /sw/nic)

```bash
cd /sw/nic
PIPELINE=rudra ASIC=vulcano P4_PROGRAM=hydra PCIEMGR_IF=1 DMA_MODE=uxdma PROFILE=qemu \
  rudra/test/tools/dol/rundol.sh \
  --pipeline rudra \
  --topo rdma_hydra \
  --feature rdma_hydra \
  --sub rdma_write \
  --nohntap
```

No tarball extraction needed when building and running in the same docker container.
PROFILE=qemu (not zephyr) — selects the qemu profile JSON for process startup.

**How to apply:** Use this exact command for hydra/vulcano DOL RDMA write tests.

## Key files
- `Makefile.build:1548` — build target definition
- `devops/jobs/level1/rudra/vulcano/test/hydra/sim/.job.yml` — CI source of truth for run commands
- `nic/rudra/test/tools/dol/rundol.sh` — main test entry point
- `nic/rudra/test/tools/dol/setup_env_sim.sh` — env vars + symlinks under /sw/nic/conf/rudra/
- `nic/rudra/src/conf/hydra/vulcano/device-pf1-coredev-llc-dol.json` — DOL device config

## Logs to watch
- `/sw/nic/model.log` — vul_model output
- `/var/log/pensando/pds-core-app.log` — wait for "Done initializing pdsagent"
- `/var/log/pensando/dp-app.log` — wait for "Pipeline initialization complete"
- `dol.log` (in /sw/nic/) — DOL test results
