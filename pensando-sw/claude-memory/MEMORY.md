# Pensando SW Development - Auto Memory

## Dev-Notes Context Repository
**Location:** `~/dev-notes/pensando-sw/`
- Complete documentation: hardware setups, automation scripts, workflows, testing guides
- 6 Vulcano setups (48 NICs, 96 consoles), multiple Salina setups
- YAML-driven automation for console mgr, firmware updates, IB testing
- **GTest automation**: `~/dev-notes/pensando-sw/scripts/run-hydra-gtest.sh`
- See [dev-notes-complete.md](dev-notes-complete.md) for complete reference
- See [testing-gtest.md](testing-gtest.md) for gtest workflow

## Memory Sync Protocol
**IMPORTANT: After updating this memory file, ALWAYS run:**
```bash
~/dev-notes/pensando-sw/scripts/sync-claude-memory.sh
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
  - Create new if doesn't exist: `~/dev-notes/pensando-sw/scripts/build-hydra.sh`
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
# After launching docker with: cd /ws/pradeept/ws/usr/src/github.com/pensando/sw/nic && make docker/shell

cd /sw

# For Vulcano/Salina builds - use proper make clean targets
make clean                    # Clean general build artifacts
make -f Makefile.ainic clean  # Clean AINIC-specific build artifacts

# Then proceed with build
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

**When to clean up containers:**
- Before every new build session (recommended)
- When switching branches (required)
- After build failures (good practice)
- Container naming: `username_YYYY-MM-DD_HH.MM.SS`

**Git submodule update (outside docker):**
- When: Switching branches, moving to new version/tag, after pulling changes
- Command: `git submodule update --init --recursive`

**make pull-assets (inside docker):**
- When: After launching new docker, switching branches, moving to new version/tag
- Command: `cd /sw && make pull-assets`

## Repository Info
- Repo path: `/ws/pradeept/ws/usr/src/github.com/pensando/sw`
- Main branch: `master`
- Product: ainic (AI NIC), ASIC: vulcano, Project: hydra (RDMA-focused)

## Most Common Build Commands (Inside Docker at /sw)

### Vulcano ASIC (AI NIC)
```bash
# Quick incremental build (after code changes)
make -C nic PIPELINE=rudra P4_PROGRAM=hydra ARCH=x86_64 ASIC=vulcano package

# Full x86 DOL build (most common for development/testing)
make -f Makefile.build build-rudra-vulcano-hydra-x86-dol
# Output: /sw/build_rudra_vulcano_hydra_x86_dol.tar.gz

# Firmware build (for hardware deployment)
make -f Makefile.build build-rudra-vulcano-hydra-ainic-fw
# Output: /sw/ainic_fw_vulcano.tar (use this for firmware updates)

# Simulator build
make -f Makefile.build build-rudra-vulcano-hydra-sim
# Output: /sw/zephyr_vulcano_hydra_sim.tar.gz
```

### Salina ASIC (AI NIC - same as Vulcano)
```bash
# Full x86 DOL build (development/testing)
make -f Makefile.build build-rudra-salina-hydra-x86-dol
# Output: /sw/build_rudra_salina_hydra_x86_dol.tar.gz

# A35 firmware only (most common - faster, skip bundle generation)
make PIPELINE=rudra P4_PROGRAM=hydra rudra-salina-ainic-a35-fw
# Output: /sw/naples_salina_a35_ainic.tar
# Use this for quick iterative builds

# Full AINIC bundle (includes A35 fw + secure fw + host tools + bundle pkg)
make -f Makefile.build build-rudra-salina-hydra-ainic-bundle
# Output: /sw/ainic_fw_salina.tar (same format as Vulcano)
# Only needed when releasing complete package

# Base AINIC bundle (Plan-B/recovery image)
make -f Makefile.build build-rudra-salina-hydra-ainic-bundle-base
# Output: /sw/naples_salina_a35_ainic_base.tar, x86 docker, host tools
```

## Key Directories
- `nic/rudra/src/hydra/` - Hydra project source (main work area)
- `nic/rudra/src/hydra/nicmgr/plugin/rdma/` - RDMA plugin code
- `platform/rtos-sw/` - RTOS/Zephyr firmware
- `nic/conf/` - Configuration files

## Testing

### GTest (Unit Tests)
**See:** [testing-gtest.md](testing-gtest.md) for complete reference

**Helper script (recommended):**
```bash
# Build (inside Docker)
~/dev-notes/pensando-sw/scripts/run-hydra-gtest.sh build

# Run specific test
~/dev-notes/pensando-sw/scripts/run-hydra-gtest.sh test resp_rx.invalid_path_id_nak

# Run all tests
~/dev-notes/pensando-sw/scripts/run-hydra-gtest.sh all
```

**Manual (if needed):**
```bash
# Build
cd /sw
make -f Makefile.build build-rudra-vulcano-hydra-gtest

# Run
cd /sw/nic
DMA_MODE=uxdma ASIC=vulcano P4_PROGRAM=hydra \
  GTEST_BINARY=/sw/nic/rudra/build/hydra/x86_64/sim/rudra/vulcano/bin/hydra_gtest \
  GTEST_FILTER='-*scale*' \
  PROFILE=qemu \
  LOG_FILE=hydra_gtest.log \
  rudra/test/tools/run_ionic_gtest.sh
```

### DOL Tests (Integration)
**See:** [project_hydra_vulcano_dol_setup.md](project_hydra_vulcano_dol_setup.md) for complete reference

Build target (NOT x86-dol — that doesn't exist for vulcano):
```bash
make -f Makefile.build build-rudra-vulcano-hydra-sw-emu
```
Run (from /sw/nic, no tarball extraction needed in same container):
```bash
PIPELINE=rudra ASIC=vulcano P4_PROGRAM=hydra PCIEMGR_IF=1 DMA_MODE=uxdma PROFILE=qemu \
  rudra/test/tools/dol/rundol.sh --pipeline rudra --topo rdma_hydra --feature rdma_hydra --sub rdma_write --nohntap
```

## Firmware Update Workflow (Same for Vulcano & Salina)

### Vulcano
1. Build: `make -f Makefile.build build-rudra-vulcano-hydra-ainic-fw`
2. Copy: `scp /sw/ainic_fw_vulcano.tar ubuntu@<HOST_IP>:/tmp/`
3. Update: `sudo nicctl update firmware -i /tmp/ainic_fw_vulcano.tar`
4. Reset: `sudo nicctl reset card --all`
5. Verify: `sudo nicctl show card` and `sudo nicctl show version`

### Salina
1. Build: `make -f Makefile.build build-rudra-salina-hydra-ainic-bundle`
2. Copy: `scp /sw/ainic_fw_salina.tar ubuntu@<HOST_IP>:/tmp/`
3. Update: `sudo nicctl update firmware -i /tmp/ainic_fw_salina.tar`
4. Reset: `sudo nicctl reset card --all`
5. Verify: `sudo nicctl show card` and `sudo nicctl show version`

## nicctl Commands
- `nicctl show card` - Show all card status
- `nicctl show version` - Show firmware version
- `nicctl reset card --all` - Reset all cards
- `nicctl update firmware -i <tar>` - Update firmware
- Add `-j` for JSON output: `nicctl show card -j`

## Hardware Setups

### Vulcano ASIC Setups
Located in: `~/dev-notes/pensando-sw/hardware/vulcano/`
- **SMC1** (10.30.75.198) - Primary dev/test, 8x Vulcano NICs (ai0-ai7), Micas switch
- **SMC2** (10.30.75.204) - Secondary dev/test, 8x Vulcano NICs (ai0-ai7), Micas switch
- GT1, GT4 - 800G Leaf-Spine topology
- Waco5, Waco6 - Arista Leaf-Spine setups

### Salina (Pollara) ASIC Setups
Located in: `~/dev-notes/pensando-sw/hardware/salina/`
- Dell-Xeon-1-2 - Paired setup (10.11.x network)
- Dell-Xeon-3-4 - Paired setup (10.30.x network)
- Dell-Genoa-3-4 - Paired setup (Plan-B images)
- Purico-Bytedance-01-02, 03-04 - ByteDance testbed (Rack J7), back-to-back within same server
- Purico-Meta-07-08, 09-10 - Meta RoCE testbed (Rack J7)
- Full inventory: `~/setups/Pollara_rdma_tb.csv`

### SMC1 Quick Reference (Most Used)
- Host: ubuntu@10.30.75.198 (password: amd123)
- 8 NICs: ai0-ai7 (benic1p1-benic8p1)
- Micas Switch: 10.30.75.77 (admin/Micas123)
- **Init script after FW update/reboot:** `/mnt/clusterfs/bringup/vulcano_hydra_rccl_bringup.sh`

## IB/RDMA Testing
Scripts located in: `~/dev-notes/pensando-sw/scripts/`

### Quick Test Commands
```bash
# Basic SMC1→SMC2 test (4 QPs)
~/dev-notes/pensando-sw/scripts/run-ib-test.sh smc1-smc2 --qp 4

# MSN context stress test (validates 128-entry window)
~/dev-notes/pensando-sw/scripts/run-ib-test.sh smc1-smc2 --qp 1 --max-msg-size 4M --direction bi --iter 2000

# Comprehensive scaling test with Excel output
~/dev-notes/pensando-sw/scripts/run-ib-test.sh smc1-smc2 --max-qp 16 --direction both --write-mode both --xlsx
```

**IMPORTANT:** Always run IB tests inside tmux session (tests take 45-60+ minutes)

## Console Access
```bash
# Console manager script (for Vulcano/SuC consoles)
~/dev-notes/pensando-sw/scripts/console-mgr.py --setup smc1 --console vulcano --all version

# Recovery after firmware update
~/dev-notes/pensando-sw/scripts/recovery-after-fw-update.sh smc1
```

## Known Issues

### Modify QP Path CC Issue (Fixed in 1.125.1+)
- **Affects:** Firmware 1.125.0-a-133 and earlier (SMC1, SMC2)
- **Symptom:** Path congestion control parameters not updated during Modify QP
- **Root cause:** `qp_set_tp_params()` called before path allocation
- **Working versions:** Firmware 1.125.1-pi-8+ (Waco5, Waco6)
- **Details:** See `~/dev-notes/pensando-sw/MODIFY-QP-PATH-CC-ISSUE.md`

### Firmware Update Recovery
- If cards don't come up after firmware update: Run recovery via SuC console reboot + host reboot
- Script: `~/dev-notes/pensando-sw/scripts/recovery-after-fw-update.sh`

## Automation Scripts
Located in: `~/dev-notes/pensando-sw/scripts/`
- `console-mgr.py` - Manage 96 console connections (Vulcano+SuC) across all setups
  - Usage: `./console-mgr.py --setup smc1 --console vulcano --all version`
  - Usage: `./console-mgr.py --setup smc1 --console suc --all reboot`
- `update-firmware.sh <setup> <tar>` - Automated firmware update
- `recovery-after-fw-update.sh <setup>` - Full recovery when cards don't come up
- `run-ib-test.sh` - IB/RDMA test wrapper
- `parallel-firmware-update.sh` - Update multiple setups simultaneously
- `sync-claude-memory.sh` - Sync MEMORY.md to dev-notes git repo

## Vulcano Hardware Setups

### SMC Setups (Development/Testing)
- **SMC1:** 10.30.75.198 (ubuntu/amd123) - 8 NICs, Micas switch
- **SMC2:** 10.30.75.204 (ubuntu/amd123) - 8 NICs, Micas switch

### Waco Cluster (Arista Leaf-Spine Topology)
- **Waco5:** 10.30.64.25 (ubuntu/amd123) - 8 NICs, Leaf1 eth1/1-8/1
- **Waco6:** 10.30.64.26 (ubuntu/amd123) - 8 NICs, Leaf1 eth9/1-16/1
- **Waco7:** 10.30.64.27 (ubuntu/amd123) - 8 NICs, Leaf2 eth1/1-8/1
- **Waco8:** 10.30.64.28 (ubuntu/amd123) - 8 NICs, Leaf2 eth9/1-16/1

**Arista Switches:**
- Spine: 10.30.64.202 (admin/Gr33nTr33s)
- Leaf1: 10.30.64.201 (Waco5-6)
- Leaf2: 10.30.64.203 (Waco7-8)

### GT Setups (800G Leaf-Spine)
- **GT1:** 10.30.69.101 (root) - 8 Vulcano NICs
- **GT4:** 10.30.69.98 - 8 Vulcano NICs

## Current Branch (as of 2026-03-05)
- Working branch: `forward_port_to_master_20260301`
- Main branch: `master`

## Related Documentation
- [context.md](file:///home/pradeept/dev-notes/pensando-sw/context.md) - Full development context
- [ib-testing-guide.md](file:///home/pradeept/dev-notes/pensando-sw/ib-testing-guide.md) - IB/RDMA testing guide
- Hardware setups: `~/dev-notes/pensando-sw/hardware/`
- IB testing guide: `~/dev-notes/pensando-sw/ib-testing-guide.md`
