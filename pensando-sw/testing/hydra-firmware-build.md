## Hydra Firmware Build - Vulcano ASIC

Build RTOS firmware for hardware deployment on Vulcano NICs.

## Quick Start

### Fully Automated Build

```bash
# Complete automation: tmux, submodules, docker, assets, firmware build
~/dev-notes/pensando-sw/scripts/build-hydra-firmware.sh

# With options
~/dev-notes/pensando-sw/scripts/build-hydra-firmware.sh --clean          # Clean before build
~/dev-notes/pensando-sw/scripts/build-hydra-firmware.sh --skip-submod    # Skip submodule update
~/dev-notes/pensando-sw/scripts/build-hydra-firmware.sh --skip-assets    # Skip pull-assets
~/dev-notes/pensando-sw/scripts/build-hydra-firmware.sh --clean-docker   # Clean Docker containers
~/dev-notes/pensando-sw/scripts/build-hydra-firmware.sh --variant m5     # Build specific variant
```

**What it does:**
1. Checks/creates tmux session
2. Updates git submodules
3. Optionally cleans Docker containers
4. Launches/detects Docker
5. Pulls assets
6. Builds firmware (20-40 min)
7. Reports completion

## Manual Build (Inside Docker)

**Inside Docker at /sw:**
```bash
cd /sw

# Pull assets
make pull-assets

# Build firmware
make -f Makefile.ainic P4_PROGRAM=hydra rudra-vulcano-ainic-fw
```

**Output files:**
- `/sw/ainic_fw_vulcano.tar` - Main firmware package
- `/sw/ainic_fw_vulcano.pldmfw` - PLDM firmware image

## Module Variants

Different firmware variants include different modules:

```bash
# Full firmware (default - all modules)
make -f Makefile.ainic P4_PROGRAM=hydra rudra-vulcano-ainic-fw

# Module variants
make -f Makefile.ainic P4_PROGRAM=hydra rudra-vulcano-ainic-fw-m1  # pciemgr, devmgr
make -f Makefile.ainic P4_PROGRAM=hydra rudra-vulcano-ainic-fw-m2  # devmgr, nicmgr
make -f Makefile.ainic P4_PROGRAM=hydra rudra-vulcano-ainic-fw-m3  # pciemgr, devmgr, nicmgr
make -f Makefile.ainic P4_PROGRAM=hydra rudra-vulcano-ainic-fw-m4  # + qosmgr
make -f Makefile.ainic P4_PROGRAM=hydra rudra-vulcano-ainic-fw-m5  # + linkmgr, hwmon (most common)
make -f Makefile.ainic P4_PROGRAM=hydra rudra-vulcano-ainic-fw-m6  # pciemgr, devmgr, linkmgr

# Gold firmware (recovery/plan-B)
make -f Makefile.ainic P4_PROGRAM=hydra rudra-vulcano-ainic-goldfw
```

**Most common:** M5 variant (includes all major managers)

## Deployment Workflow

### Step 1: Copy to Host

```bash
# From Docker or build machine
scp /sw/ainic_fw_vulcano.tar ubuntu@<HOST_IP>:/tmp/
```

### Step 2: Update Firmware

```bash
# SSH to host
ssh ubuntu@<HOST_IP>

# Update firmware (takes 3-5 minutes)
sudo nicctl update firmware -i /tmp/ainic_fw_vulcano.tar
```

### Step 3: Reset Cards

```bash
# Reset all cards
sudo nicctl reset card --all

# Wait 30 seconds for cards to come up
sleep 30
```

### Step 4: Verify

```bash
# Check all cards are up
sudo nicctl show card

# Verify firmware version
sudo nicctl show version

# Check for errors
sudo nicctl show card -j | jq '.cards[].state'
```

## Build Time

- **Clean build**: 30-40 minutes
- **Incremental build**: 10-20 minutes (after code changes)

## Build Artifacts

| File | Size | Purpose |
|------|------|---------|
| `ainic_fw_vulcano.tar` | ~50-80 MB | Main firmware package (zephyr.fit + configs) |
| `ainic_fw_vulcano.pldmfw` | ~50-80 MB | PLDM format firmware |
| `platform/rtos-sw/external/ainic-rtos/build/zephyr/zephyr.fit` | ~50 MB | FIT image (Firmware Image Tree) |

## Troubleshooting

### Build Fails - Missing Assets

```bash
# Pull assets explicitly
cd /sw
make pull-assets-ainic-rudra-vulcano
```

### Build Fails - Zephyr Errors

```bash
# Clean firmware build artifacts
cd /sw
make -f Makefile.ainic clean-fw

# Rebuild
make -f Makefile.ainic P4_PROGRAM=hydra rudra-vulcano-ainic-fw
```

### Deployment Fails - Cards Don't Come Up

```bash
# Check card status
sudo nicctl show card -j

# Reset specific card
sudo nicctl reset card ai0

# Check console output
# Use ~/dev-notes/pensando-sw/scripts/console-mgr.py
```

## References

- **Build definition**: Makefile.ainic lines 113-116
- **Packaging script**: `nic/tools/ainic/firmware/vulcano/pkg-image.sh`
- **RTOS build**: `platform/rtos-sw/scripts/ainic-rtos-cmake.sh`
- **Deployment guide**: `~/dev-notes/pensando-sw/FIRMWARE-UPDATE-QUICKREF.md`
