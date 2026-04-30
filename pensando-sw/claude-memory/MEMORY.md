# Pensando SW Development - Auto Memory

## Dev-Notes Context Repository
**Location:** `~/dev-notes/pensando-sw/`
- Hardware setups: 6 Vulcano setups (48 NICs, 96 consoles), multiple Salina setups
- Private skills: console management, health check, recovery
- Reference docs, archived investigations, testbed YAMLs
- See [dev-notes-complete.md](dev-notes-complete.md) for complete reference

## Memory Sync Protocol
**IMPORTANT: After updating this memory file, ALWAYS run:**
```bash
~/dev-notes/pensando-sw/.claude/skills/scripts/infra/sync-claude-memory.sh
```
This automatically commits and pushes changes so all machines stay in sync.

**To pull latest memory on any machine:**
```bash
cd ~/dev-notes && git pull
```

## Critical Build and Test Requirements
- **ALWAYS use tmux for builds AND long-running tests**: Session name is ALWAYS `pensando-sw` (one per workspace)
  - Check existing session: `tmux ls | grep pensando-sw`
  - Attach to existing: `tmux attach -t pensando-sw`
  - Protects against SSH disconnects, allows background builds
  - Detach: `Ctrl+b d`, Reattach: `tmux attach -t pensando-sw`
  - **IMPORTANT:** Reuse same session across Claude sessions - check if it exists first!
  - **IB/RDMA Tests**: ALWAYS run in tmux window (tests take 45-60+ minutes, network interruptions fatal)
- **ALWAYS build inside Docker**: All builds MUST run in Docker container
- Check if in docker: `pwd` should show `/sw` (not `/ws/pradeept/...`)
- **Update submodules FIRST (outside docker)**: `git submodule update --init --recursive` when switching branches/versions
- **ALWAYS clean up workspace containers before starting**: `docker ps -a | grep "$(whoami)_" | awk '{print $1}' | xargs -r docker stop | xargs -r docker rm`
- Launch docker: `cd /ws/pradeept/ws/usr/src/github.com/pensando/sw/nic && make docker/shell`
- **Inside docker, pull assets**: `cd /sw && make pull-assets` after launching docker or switching branches

## Clean Build Procedure
For a clean build (removes all build artifacts):
```bash
# MUST run inside Docker (build dirs created with root permissions)
cd /sw
make clean                    # Clean general build artifacts
make -f Makefile.ainic clean  # Clean AINIC-specific build artifacts
make pull-assets
make -f Makefile.build build-rudra-<asic>-hydra-<target>
```

## Docker Container Management
```bash
# Check for existing workspace containers
docker ps -a | grep "$(whoami)_"

# Clean up workspace containers (recommended before every build)
docker ps -a | grep "$(whoami)_" | awk '{print $1}' | xargs -r docker stop | xargs -r docker rm
```

## Repository Info
- Repo path: `/ws/pradeept/ws/usr/src/github.com/pensando/sw`
- Main branch: `master`
- Product: ainic (AI NIC), ASIC: vulcano, Project: hydra (RDMA-focused)

## Build & Test — Use Repo Skills
Build, test, and deploy workflows are now repo skills (from Vijay's PR #115193).
Use `/build`, `/gtest`, `/dol`, `/deploy`, `/benchmark` etc. instead of dev-notes scripts.

### Most Common Build Commands (Inside Docker at /sw)
```bash
# Quick incremental build
make -C nic PIPELINE=rudra P4_PROGRAM=hydra ARCH=x86_64 ASIC=vulcano package

# Full x86 DOL build
make -f Makefile.build build-rudra-vulcano-hydra-x86-dol

# Firmware build
make -f Makefile.build build-rudra-vulcano-hydra-ainic-fw

# GTest build
make -f Makefile.build build-rudra-vulcano-hydra-gtest

# DOL/SW-EMU build
make -f Makefile.build build-rudra-vulcano-hydra-sw-emu
```

### GTest (Inside Docker)
```bash
cd /sw/nic
DMA_MODE=uxdma ASIC=vulcano P4_PROGRAM=hydra \
  GTEST_BINARY=/sw/nic/rudra/build/hydra/x86_64/sim/rudra/vulcano/bin/hydra_gtest \
  GTEST_FILTER='-*scale*' \
  PROFILE=qemu \
  LOG_FILE=hydra_gtest.log \
  rudra/test/tools/run_ionic_gtest.sh
```

### DOL Tests (Inside Docker)
```bash
cd /sw/nic
PIPELINE=rudra ASIC=vulcano P4_PROGRAM=hydra PCIEMGR_IF=1 DMA_MODE=uxdma PROFILE=qemu \
  rudra/test/tools/dol/rundol.sh --pipeline rudra --topo rdma_hydra --feature rdma_hydra --sub rdma_write --nohntap
```

## Key Directories
- `nic/rudra/src/hydra/` - Hydra project source (main work area)
- `nic/rudra/src/hydra/nicmgr/plugin/rdma/` - RDMA plugin code
- `platform/rtos-sw/` - RTOS/Zephyr firmware
- `nic/conf/` - Configuration files

## Firmware Update Workflow
1. Build: `make -f Makefile.build build-rudra-vulcano-hydra-ainic-fw`
2. Copy: `scp /sw/ainic_fw_vulcano.tar ubuntu@<HOST_IP>:/tmp/`
3. Update: `sudo nicctl update firmware -i /tmp/ainic_fw_vulcano.tar`
4. Reset: `sudo nicctl reset card --all`
5. Verify: `sudo nicctl show card` and `sudo nicctl show version`

## Private Skills (~/dev-notes/pensando-sw/.claude/skills/)
- `/console` — Manage Vulcano/SuC consoles (version, reboot, status, custom commands)
- `/health-check` — Parallel health check across hosts + NICs for any setup
- `/recover` — Step-by-step recovery when NICs fail after firmware update

## Console Access
```bash
~/dev-notes/pensando-sw/.claude/skills/scripts/console/console-mgr.py --setup smc1 --console vulcano --all version
~/dev-notes/pensando-sw/.claude/skills/scripts/console/console-mgr.py --setup smc1 --console suc --all reboot
```

## Hardware Setups

### Vulcano Setups (~/dev-notes/pensando-sw/hardware/vulcano/)
- **SMC1** (10.30.75.198) - 8x Vulcano NICs, Micas switch
- **SMC2** (10.30.75.204) - 8x Vulcano NICs, Micas switch
- **Waco5-8** - Arista Leaf-Spine cluster (32 NICs total)
- **GT1, GT4** - 800G Leaf-Spine topology

### Salina Setups (~/dev-notes/pensando-sw/hardware/salina/)
- Dell-Xeon pairs, Dell-Genoa pair, Purico-Bytedance pairs, Purico-Meta pairs

## Skills
- [skill-analyze-latency.md](skill-analyze-latency.md) — `/analyze-latency` RDMA pipeline latency analysis via mputrace

## Reference Docs
- `~/dev-notes/pensando-sw/reference/` — ONBOARDING-MAP, FIRMWARE-PARTITION-SWITCH, HYDRA-AUTOCLEAR, etc.
- `~/dev-notes/pensando-sw/archive/` — Historical investigations (NFS, GT-bandwidth, ModifyQP bugs)
