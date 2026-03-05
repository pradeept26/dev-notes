# Pensando SW Development - Auto Memory

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
```bash
# GTest (after x86 DOL build)
tar -zxf /sw/build_rudra_vulcano_hydra_x86_dol.tar.gz -C /
cd /sw/nic
DMA_MODE=uxdma ASIC=vulcano ./rudra/test/tools/run_gtests.sh --p4_program hydra --bin hydra_gtest --gtest_filter=-*scale*

# DOL Tests (requires both x86 and sim builds)
PIPELINE=rudra ASIC=vulcano P4_PROGRAM=hydra PCIEMGR_IF=1 DMA_MODE=uxdma PROFILE=zephyr \
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
Located in: `~/dev-notes/pensando-sw/hardware/vulcano/`
- SMC1, SMC2 - Development/testing
- GT1, GT4 - 800G Leaf-Spine topology
- Waco5, Waco6 - Arista Leaf-Spine setups

## Common Issues
- If cards don't come up after firmware update: Run recovery via SuC console reboot + host reboot
- See `~/dev-notes/pensando-sw/scripts/recovery-after-fw-update.sh`

## Related Documentation
- [context.md](file:///home/pradeept/dev-notes/pensando-sw/context.md) - Full development context
- Hardware setups: `~/dev-notes/pensando-sw/hardware/`
