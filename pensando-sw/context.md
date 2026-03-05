# Pensando SW - Development Context

## Repository
- Path: `/ws/pradeept/ws/usr/src/github.com/pensando/sw`
- Main branch: `master`
- Current work: `1x400g-breakout` branch

## Docker Environment

**IMPORTANT**: All builds MUST be done inside Docker container.

### Check if Docker is Running
```bash
# Check if already in docker (look for /sw path or DOCKER_ENV variable)
pwd  # If inside docker, you'll be in /sw
echo $DOCKER_ENV  # Will show value if in docker
```

### Launch Docker Container
```bash
# From sw/nic directory
cd /ws/pradeept/ws/usr/src/github.com/pensando/sw/nic
make docker/shell

# Inside docker, pull dependencies
cd /sw
make pull-assets
```

### Docker Workflow Helper
```bash
# Step 1: Check if already inside Docker
pwd  # Should show /sw if in docker

# Step 2: If on host, update git submodules (IMPORTANT: Outside docker)
# Required when: switching branches, moving to new version/tag
cd /ws/pradeept/ws/usr/src/github.com/pensando/sw
git submodule update --init --recursive

# Step 3: Check for existing workspace containers
docker ps -a | grep "$(whoami)_"

# Step 4: Clean up workspace containers (always recommended for fresh start)
docker ps -a | grep "$(whoami)_" | awk '{print $1}' | xargs -r docker stop | xargs -r docker rm

# Step 5: Launch new Docker container
cd /ws/pradeept/ws/usr/src/github.com/pensando/sw/nic
make docker/shell

# Step 6: Inside docker, pull dependencies
# Required when: launching new docker, switching branches, moving to new version
cd /sw && make pull-assets
```

### Docker Container Management

**Check for existing workspace containers:**
```bash
# List all Docker containers for this workspace
docker ps -a | grep "$(whoami)_"

# Example output shows container ID, image, status, and timestamp-based name
# CONTAINER ID   IMAGE          STATUS    NAMES
# abc123def456   pensando/nic   Exited    pradeept_2026-03-03_10.30.45
```

**Clean up workspace containers:**
```bash
# Stop and remove all workspace-related containers
# Recommended: Before switching branches or starting fresh builds
docker ps -a | grep "$(whoami)_" | awk '{print $1}' | xargs -r docker stop | xargs -r docker rm

# Verify cleanup
docker ps -a | grep "$(whoami)_"  # Should return empty
```

**When to clean up containers:**
- **Always recommended:** Before every new build session
- **Required:** When switching branches
- **Good practice:** After build failures or when starting fresh
- **Ensures:** Clean, reproducible build environment

**When to run `git submodule update` (outside docker):**
- When switching branches
- When moving to new version or tag
- After pulling changes that update submodules
- Command: `git submodule update --init --recursive`

**When to run `make pull-assets` (inside docker):**
- After launching new docker container
- When switching branches
- When moving to new version or tag
- After cleaning docker containers

### Docker Best Practices

**Always start with fresh Docker container:**
- Clean up workspace containers before starting new builds
- Recommended when switching branches (to avoid config conflicts)
- Recommended after build failures (to start with clean state)
- Ensures consistent, reproducible build environment

**Container cleanup command:**
```bash
# Stop and remove only workspace-related containers
docker ps -a | grep "$(whoami)_" | awk '{print $1}' | xargs -r docker stop | xargs -r docker rm
```

**Container naming:**
- Format: `username_YYYY-MM-DD_HH.MM.SS`
- Each `make docker/shell` creates a new container with timestamp
- Grep pattern `$(whoami)_` finds all your containers

### Tmux-Based Build Workflow

**Why use tmux:**
- Builds continue if SSH session disconnects
- Detach from long builds, reattach later to check progress
- Run builds in background while working on other tasks
- Single tmux session per workspace for consistency

**Tmux session management:**
```bash
# Session name (one per workspace)
TMUX_SESSION="pensando-sw"

# Check if tmux session exists
tmux ls

# Create new session (if doesn't exist)
tmux new-session -s pensando-sw -c /ws/pradeept/ws/usr/src/github.com/pensando/sw

# Attach to existing session
tmux attach -t pensando-sw

# Detach from session (inside tmux)
# Press: Ctrl+b then d

# Kill session (when done)
tmux kill-session -t pensando-sw
```

**Helper script:**
```bash
# Use helper script for automated tmux management
~/dev-notes/pensando-sw/scripts/build-hydra.sh

# Script auto-creates or attaches to tmux session
# Then run build commands inside tmux
```

**Typical workflow:**
1. Run helper script: `~/dev-notes/pensando-sw/scripts/build-hydra.sh`
2. Script creates/attaches to tmux session `pensando-sw`
3. Inside tmux, run standard build workflow:
   ```bash
   # Update submodules
   cd /ws/pradeept/ws/usr/src/github.com/pensando/sw
   git submodule update --init --recursive

   # Clean Docker containers
   docker ps -a | grep "$(whoami)_" | awk '{print $1}' | xargs -r docker stop | xargs -r docker rm

   # Launch Docker
   cd nic && make docker/shell

   # Inside Docker: pull assets and build
   cd /sw && make pull-assets
   make -f Makefile.build build-rudra-vulcano-hydra-x86-dol
   ```
4. Detach with `Ctrl+b d` - build continues in background
5. Reattach anytime with `tmux attach -t pensando-sw`

## Build Commands (Inside Docker)

### Hydra Builds for Vulcano

**Primary Build Targets (via Makefile.build):**
```bash
# All commands run from /sw/ inside docker

# 1. Hydra x86 DOL (Development/Testing) - MOST COMMON
make -f Makefile.build build-rudra-vulcano-hydra-x86-dol
# Direct command: make -C nic PIPELINE=rudra P4_PROGRAM=hydra ARCH=x86_64 ASIC=vulcano package
# Output: /sw/build_rudra_vulcano_hydra_x86_dol.tar.gz

# 2. Hydra Simulator Build
make -f Makefile.build build-rudra-vulcano-hydra-sim
# Direct command: make -f Makefile.ainic rudra-vulcano-hydra-sim
# Output: /sw/zephyr_vulcano_hydra_sim.tar.gz

# 3. Hydra Software Emulator
make -f Makefile.build build-rudra-vulcano-hydra-sw-emu
# Direct command: make -f Makefile.ainic rudra-vulcano-hydra-sw-emu
# Output: /sw/zephyr_vulcano_sw_emu.tar.gz

# 4. Hydra Firmware (PLDMFW image for hardware)
make -f Makefile.build build-rudra-vulcano-hydra-ainic-fw
# Direct command: make -f Makefile.ainic P4_PROGRAM=hydra rudra-vulcano-ainic-fw
# Output: /sw/ainic_fw_vulcano.tar, /sw/ainic_fw_vulcano.pldmfw

# 5. Complete Bundle (FW + tools + drivers)
make -f Makefile.build build-rudra-vulcano-hydra-ainic-bundle
# Output: /sw/ainic_bundle_rudra_vulcano_hydra.tar.gz
```

**Direct Low-level Targets (via Makefile.ainic):**
```bash
# For quick incremental builds

# x86 DOL package
make -C nic PIPELINE=rudra P4_PROGRAM=hydra ARCH=x86_64 ASIC=vulcano package

# Simulator model (prerequisite for sim builds)
make -f Makefile.ainic rudra-vulcano-sim-model

# Hydra simulator
make -f Makefile.ainic rudra-vulcano-hydra-sim

# Hydra SW emulator
make -f Makefile.ainic rudra-vulcano-hydra-sw-emu

# Firmware builds
make -f Makefile.ainic P4_PROGRAM=hydra rudra-vulcano-ainic-fw
make -f Makefile.ainic P4_PROGRAM=hydra rudra-vulcano-ainic-goldfw
```

**Host Tools:**
```bash
# Debug tools (vulcanomon, vulaxitrace, capview, mputrace)
make -f Makefile.build build-rudra-vulcano-hydra-ainic-dbg-tools
# Output: /sw/rudra_vulcano_hydra_host_ainic-dbg-tools_pkg.tar.gz

# nicctl (firmware update, techsupport, management)
make -f Makefile.build build-rudra-vulcano-hydra-ainic-nicctl
# Output: /sw/rudra_vulcano_hydra_host_nicctl_pkg.tar.gz
```

### Clean Build
```bash
# Inside docker at /sw
make -f Makefile.ainic clean
# Or clean just firmware
make -f Makefile.ainic clean-fw
```

### Build Variables
- `ASIC=vulcano` (default in Makefile.ainic)
- `PIPELINE=rudra` (default)
- `P4_PROGRAM=pulsar|hydra|quasar` (specify your program)
- `PLATFORM=hw` (default, or `sim` for simulator)
- `ARCH=x86_64` (default) or `riscv` for firmware

## Project Structure

### Key Directories
- `nic/rudra/src/hydra/` - Hydra project source (your main work area)
  - `nic/rudra/src/hydra/nicmgr/` - NIC manager
  - `nic/rudra/src/hydra/nicmgr/plugin/rdma/` - RDMA plugin (admincmd_handler.c)
- `nic/rudra/src/pulsar/` - Pulsar project
- `nic/rudra/src/quasar/` - Quasar project
- `platform/rtos-sw/` - RTOS/Zephyr firmware
- `nic/conf/` - Configuration files
- `Makefile.ainic` - Main build file for ainic family (vulcano/salina)

### Build Outputs
- `/sw/nic/build/x86_64/` - x86 builds
- `/sw/platform/rtos-sw/external/ainic-rtos/build/` - RTOS firmware builds
- `/sw/ainic_fw_vulcano.tar` - Packaged firmware tarball
- `/sw/ainic_fw_vulcano.pldmfw` - PLDM firmware image

### Important Files
- Recent changes: `nic/rudra/src/hydra/nicmgr/plugin/rdma/admincmd_handler.c`
- Build configs: `platform/rtos-sw/scripts/ainic-rtos-cmake.sh`
- Firmware packaging: `nic/tools/ainic/firmware/vulcano/pkg-image.sh`

## Hardware Setup

Hardware setups are documented in: `~/dev-notes/pensando-sw/hardware/vulcano/`
- SMC1, SMC2 - Development/testing setups
- GT1, GT4 - 800G Leaf-Spine topology
- Waco5, Waco6 - Arista Leaf-Spine setups

See hardware/*.md files for detailed setup information.

## Firmware Update Procedure

**See also:** [Firmware Partition Switch Procedure](./FIRMWARE-PARTITION-SWITCH.md) for switching between firmware partitions without reflashing.

### Complete Firmware Update Workflow

**Step 1: Build Firmware**
```bash
# Inside Docker at /sw
make -f Makefile.build build-rudra-vulcano-hydra-ainic-fw

# Output files:
# - /sw/ainic_fw_vulcano.tar      ← USE THIS for firmware update
# - /sw/ainic_fw_vulcano.pldmfw   (PLDM format)
```

**Step 2: Copy Firmware to Host**
```bash
# From your build machine (outside Docker)
# Copy the tarball to the target host
scp /sw/ainic_fw_vulcano.tar ubuntu@<HOST_IP>:/tmp/

# Examples:
scp /sw/ainic_fw_vulcano.tar ubuntu@10.30.75.198:/tmp/  # SMC1
scp /sw/ainic_fw_vulcano.tar ubuntu@10.30.75.204:/tmp/  # SMC2
scp /sw/ainic_fw_vulcano.tar root@10.30.69.101:/tmp/    # GT1
scp /sw/ainic_fw_vulcano.tar ubuntu@10.30.64.25:/tmp/   # Waco5
```

**Step 3: Update Firmware (on target host)**
```bash
# SSH to the host
ssh ubuntu@<HOST_IP>

# Update firmware to alternate partition
# This takes 3-5 minutes and shows progress
sudo nicctl update firmware -i /tmp/ainic_fw_vulcano.tar

# The firmware is written to the alternate partition
# On successful update, no errors are displayed
```

**Step 4: Reset Cards to Activate New Firmware**
```bash
# Reboot all NICs to activate the new firmware
sudo nicctl reset card --all

# This triggers cards to boot from the new firmware partition
```

**Step 5: Verify All Cards Are Up**
```bash
# Check card status (should show all 8 cards)
sudo nicctl show card

# Verify firmware version
sudo nicctl show version

# Check in JSON format (useful for automation)
sudo nicctl show card -j
sudo nicctl show version -j

# Verify RDMA devices
ibv_devices
# Should show: ai0, ai1, ai2, ai3, ai4, ai5, ai6, ai7
```

### Troubleshooting Firmware Updates

**If cards don't come up after reset (Common Issue):**

This requires a specific recovery procedure:

**Recovery Steps:**

1. **Verify firmware on Vulcano consoles**
   ```bash
   cd ~/dev-notes/pensando-sw/scripts
   ./console-mgr.py --setup smc1 --console vulcano --all version
   # Confirms firmware actually updated
   ```

2. **Reboot Vulcano via SuC consoles**
   ```bash
   ./console-mgr.py --setup smc1 --console suc --all reboot
   # Executes "kernel reboot" on all SuC consoles
   ```

3. **Reboot the host**
   ```bash
   ssh ubuntu@10.30.75.198 'sudo reboot'
   ```

4. **Wait for host (2-3 minutes)**
   ```bash
   sleep 120
   ssh ubuntu@10.30.75.198 'uptime'
   ```

5. **Verify all cards**
   ```bash
   ssh ubuntu@10.30.75.198 'sudo nicctl show card'
   # Should show all 8 cards
   ```

**Automated Recovery Script:**
```bash
cd ~/dev-notes/pensando-sw/scripts
./recovery-after-fw-update.sh smc1
# Runs complete recovery workflow automatically
```

### nicctl Command Reference

**Common nicctl Commands:**
```bash
# Card management
nicctl show card              # Show all card status
nicctl show card -j           # JSON output
nicctl reset card --all       # Reset all cards
nicctl reset card <card_id>   # Reset specific card

# Firmware management
nicctl update firmware -i <tar_file>   # Update firmware
nicctl show version                    # Show firmware version
nicctl show version -j                 # JSON output

# LIF (Logical Interface) management
nicctl show lif               # Show logical interfaces
nicctl show lif -j            # JSON output

# Device information
nicctl show device            # Show device details

# Techsupport
nicctl techsupport <output_file>  # Collect debug data
```

**JSON Output:**
Most `nicctl show` commands support `-j` flag for JSON output, useful for automation:
```bash
nicctl show card -j | jq .
nicctl show version -j | jq .
nicctl show lif -j | jq '.[] | select(.name | startswith("enp"))'
```

**nicctl Source Code:**
For detailed information on available options:
- Path: `nic/infra/ainic/nicctl/`
- Study source code for advanced usage and debugging

## Testing

### GTest (Unit Tests)
```bash
# After building x86 DOL package
# Extract the build tarball
tar -zxf /sw/build_rudra_vulcano_hydra_x86_dol.tar.gz -C /

# Run hydra gtests
cd /sw/nic
DMA_MODE=uxdma ASIC=vulcano ./rudra/test/tools/run_gtests.sh --p4_program hydra --bin hydra_gtest --gtest_filter=-*scale*

# Run hydra AQ (Admin Queue) gtests
DMA_MODE=uxdma ASIC=vulcano ./rudra/test/tools/run_gtests.sh --p4_program hydra --bin hydra_gtest_aq --gtest_filter=-*scale*
```

### DOL Tests (Data-path On-chip Logic Tests)
```bash
# Requires both x86 DOL build and simulator build
tar -zxf /sw/build_rudra_vulcano_hydra_x86_dol.tar.gz -C /
tar -zxf /sw/zephyr_vulcano_hydra_sim.tar.gz -C /

cd /sw/nic

# Run RDMA write DOL tests
PIPELINE=rudra ASIC=vulcano P4_PROGRAM=hydra PCIEMGR_IF=1 DMA_MODE=uxdma PROFILE=zephyr \
  rudra/test/tools/dol/rundol.sh --pipeline rudra --topo rdma_hydra --feature rdma_hydra --sub rdma_write --nohntap

# Run RDMA send DOL tests
PIPELINE=rudra ASIC=vulcano P4_PROGRAM=hydra PCIEMGR_IF=1 DMA_MODE=uxdma PROFILE=zephyr \
  rudra/test/tools/dol/rundol.sh --pipeline rudra --topo rdma_hydra --feature rdma_hydra --sub rdma_send --nohntap

# Run Classic NIC (CNIC) DOL tests
PIPELINE=rudra ASIC=vulcano P4_PROGRAM=hydra PCIEMGR_IF=1 DMA_MODE=uxdma PROFILE=zephyr \
  rudra/test/tools/dol/rundol.sh --pipeline rudra --topo host --feature classic_hydra --cnic --nohntap
```

### P4+ Unit Tests
```bash
# Extract build tarball
tar -zxf /sw/build_rudra_vulcano_hydra_x86_dol.tar.gz -C /

cd /sw/nic

# TX path tests
cd rudra/src/hydra/p4/p4plus-16/meta_roce/tx/test
ASIC=vulcano py.test

# RX path tests
cd rudra/src/hydra/p4/p4plus-16/meta_roce/rx/test
ASIC=vulcano py.test
```

### QEMU System Tests
```bash
# After building SW emulator
# Tests full system with QEMU
bash /sw/devops/jobs/level1/rudra/vulcano/test/hydra/sim/hydra-vulcano-qemu-system-test.sh
# Logs: /sw/nic/root_qemu_*.log, /sw/nic/model.log
```

### JSON Validation (Installation Bundle)
```bash
# Validates JSON configs in the bundle
tar xvf /sw/ainic_bundle_rudra_vulcano_hydra.tar.gz -C /
cd /ainic_bundle* && tar xzvf host_sw_pkg.tar.gz && cd host_sw_pkg
tar xvf ./ipc_driver/src/drivers-linux-ipc.tar.xz
PIPELINE=rudra P4_PROGRAM=hydra ASIC=vulcano /sw/devops/tools/rudra/hydra/install/validate_json.sh .
```

### Hardware Tests
- **TODO**: Document hardware test workflow
- **TODO**: Add test scripts or procedures
- Location: `/sw/devops/jobs/level1/rudra/vulcano/test/e2e/hw/hydra/.job.yml`

## Common Workflows

### Complete Build Workflow
```bash
# 0. Check if already in Docker
pwd  # Shows /sw if in docker, /ws/pradeept/... if on host

# 1. If on host, update git submodules (outside docker)
# IMPORTANT: Do this when switching branches or moving to new version/tag
cd /ws/pradeept/ws/usr/src/github.com/pensando/sw
git submodule update --init --recursive

# 2. Check for existing workspace containers
docker ps -a | grep "$(whoami)_"

# 3. Clean up workspace containers (recommended for fresh start)
docker ps -a | grep "$(whoami)_" | awk '{print $1}' | xargs -r docker stop | xargs -r docker rm

# 4. Launch docker
cd /ws/pradeept/ws/usr/src/github.com/pensando/sw/nic
make docker/shell

# 5. Inside docker, pull assets
# IMPORTANT: Required after launching new docker, switching branches, or moving to new version
cd /sw
make pull-assets
# Or specific asset sets:
# make pull-assets-ainic-rudra-vulcano-sim  # For simulation
# make pull-assets-ainic-rudra-vulcano      # For firmware
# make pull-assets-zephyr-vulcano           # For Zephyr/RTOS

# 6. Build hydra (choose one):
# For development/testing:
make -f Makefile.build build-rudra-vulcano-hydra-x86-dol
# For firmware:
make -f Makefile.build build-rudra-vulcano-hydra-ainic-fw
# For simulation:
make -f Makefile.build build-rudra-vulcano-hydra-sim

# 7. Run tests (optional)
# See Testing section for specific test commands
```

### Quick Incremental Build
```bash
# Inside docker at /sw
# For source code changes (fastest)
make -C nic PIPELINE=rudra P4_PROGRAM=hydra ARCH=x86_64 ASIC=vulcano package

# For firmware changes
make -f Makefile.ainic P4_PROGRAM=hydra rudra-vulcano-ainic-fw
```

### Development Iteration Cycle
```bash
# Typical workflow for code changes:
# 1. Edit code in nic/rudra/src/hydra/
# 2. Incremental build
make -C nic PIPELINE=rudra P4_PROGRAM=hydra ARCH=x86_64 ASIC=vulcano package
# 3. Run relevant tests
DMA_MODE=uxdma ASIC=vulcano ./rudra/test/tools/run_gtests.sh --p4_program hydra --bin hydra_gtest
# 4. Iterate
```

### Debugging
**Debug Tools:**
- GDB for x86 builds
- Simulator with model_sim_cli.bin
- RDMA debug: `nic/rudra/tools/ainic/debug/collect_ainic_info.py`
- ASIC monitoring: vulcanomon, vulaxitrace

**Log Locations:**
- **TODO**: Add log file paths
- Likely in `/var/log/` or `/sw/nic/build/` depending on target

**Common Debug Commands:**
```bash
# Inside docker
# Build debug/trace tools
make -f Makefile.ainic rudra-vulcano-ainic-dbg-tools-bin

# TODO: Add specific debugging workflows
```

## Dependencies

### Required in Docker
- Docker container has all build dependencies pre-installed
- Zephyr SDK (v4.0.0) - sourced via `tools/zephyr/zephyr-v4.0.0/settings.sh`
- CMake, Ninja build system
- RISC-V toolchain for firmware builds

### Asset Dependencies
```bash
# Pull before building (inside docker at /sw)
make pull-assets

# For specific sorrento tools (if needed)
# wsctl assets get --name sorrento_tools --version ${VULCANO_SORRENTO_BUILD}
```

## Git Workflow

### Common Git Commands
```bash
# Check status
git status

# View changes
git diff
git diff master...HEAD  # See all changes in branch

# Create commit (outside docker, in /ws/pradeept/.../sw)
git add <files>
git commit -m "message"

# Push to remote
git push origin 1x400g-breakout
```

## Notes
- **Current work**: 1x400g-4 breakout implementation on `1x400g-breakout` branch
- **Recent changes**: `nic/rudra/src/hydra/nicmgr/plugin/rdma/admincmd_handler.c`
- **Product family**: ainic (AI NIC)
- **Primary ASIC**: vulcano
- **Primary project**: hydra (RDMA focused)

## Quick Reference

### Most Used Commands
```bash
# 0. Create/attach to tmux session (recommended for builds)
~/dev-notes/pensando-sw/scripts/build-hydra.sh
# Or manually: tmux new-session -s pensando-sw OR tmux attach -t pensando-sw

# 1. Check if in docker
pwd  # Should show /sw if in docker

# 2. Update git submodules (outside docker, when switching branches/versions)
cd /ws/pradeept/ws/usr/src/github.com/pensando/sw && git submodule update --init --recursive

# 3. List workspace containers (if on host)
docker ps -a | grep "$(whoami)_"

# 4. Clean up workspace containers (recommended before every build)
docker ps -a | grep "$(whoami)_" | awk '{print $1}' | xargs -r docker stop | xargs -r docker rm

# 5. Launch docker (from nic/ dir)
cd /ws/pradeept/ws/usr/src/github.com/pensando/sw/nic && make docker/shell

# 6. Inside docker - pull assets (after launching docker or switching branches)
cd /sw && make pull-assets

# 7. Quick incremental build (after code changes)
make -C nic PIPELINE=rudra P4_PROGRAM=hydra ARCH=x86_64 ASIC=vulcano package

# 8. Full build (for packaging/CI)
make -f Makefile.build build-rudra-vulcano-hydra-x86-dol

# 9. Run gtests
DMA_MODE=uxdma ASIC=vulcano /sw/nic/rudra/test/tools/run_gtests.sh --p4_program hydra --bin hydra_gtest

# 10. Clean build
make -f Makefile.ainic clean

# Tmux shortcuts (inside tmux):
# Detach: Ctrl+b then d
# Reattach: tmux attach -t pensando-sw
# List sessions: tmux ls
```

### Build Artifacts & Outputs
**x86 DOL Build:**
- Tarball: `/sw/build_rudra_vulcano_hydra_x86_dol.tar.gz`
- Build directory: `/sw/nic/build/x86_64/hw/rudra/vulcano/`
- Binaries: `/sw/nic/build/x86_64/hw/rudra/vulcano/bin/`
- Libraries: `/sw/nic/build/x86_64/hw/rudra/vulcano/lib/`
- P4 configs: `/sw/nic/conf/gen/`

**Firmware:**
- Tarball: `/sw/ainic_fw_vulcano.tar`
- PLDMFW image: `/sw/ainic_fw_vulcano.pldmfw` (flash to hardware)
- Build archive: `/sw/build-rudra-vulcano-hydra-ainic-fw.tar.gz`

**Simulator:**
- Tarball: `/sw/zephyr_vulcano_hydra_sim.tar.gz`
- Zephyr executable: `/sw/platform/rtos-sw/build/zephyr/zephyr.exe`
- FW meta blob: `/sw/fw_meta_blob.bin`

**Bundle (Complete Package):**
- Bundle: `/sw/ainic_bundle_rudra_vulcano_hydra.tar.gz`
  - Contains: firmware, nicctl, debug tools, drivers, monitoring tools

**Test Logs:**
- GTest logs: `/sw/nic/nic_sanity_logs.tar.gz`
- QEMU logs: `/sw/nic/root_qemu_*.log`
- Model logs: `/sw/nic/model.log`

---
Last updated: 2026-02-25
