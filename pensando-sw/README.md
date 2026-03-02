# Pensando SW - Development Notes & Context

Complete development context, hardware setups, and automation tools for Pensando SW Hydra/Vulcano development.

## 🚀 Quick Start

### For Claude Code Sessions
```
Just say: "Read my pensando-sw context"
Claude will automatically load all build commands, hardware setups, and workflows.
```

### For Daily Development
```bash
# Build firmware
make -f Makefile.build build-rudra-vulcano-hydra-ainic-fw

# Update firmware on SMC1
~/dev-notes/pensando-sw/scripts/update-firmware.sh smc1 /sw/ainic_fw_vulcano.tar

# Check console versions
~/dev-notes/pensando-sw/scripts/console-mgr.py --setup smc1 --console vulcano --all version
```

## 📁 Repository Structure

```
pensando-sw/
├── README.md                          # This file
├── context.md                         # Main development guide
├── FIRMWARE-UPDATE-QUICKREF.md        # Firmware update cheat sheet
├── hardware/                          # Hardware setups
│   ├── README.md                      # Hardware overview
│   └── vulcano/
│       ├── data/                      # YAML data (automation)
│       │   ├── smc1.yml               # SMC1 config
│       │   ├── smc2.yml               # SMC2 config
│       │   ├── gt1.yml                # GT1 config
│       │   ├── gt4.yml                # GT4 config
│       │   ├── waco5.yml              # Waco5 config
│       │   └── waco6.yml              # Waco6 config
│       ├── smc1.md                    # SMC1 documentation
│       └── smc2.md                    # SMC2 documentation
└── scripts/                           # Automation scripts
    ├── README.md                      # Scripts documentation
    ├── console-mgr.py                 # Console manager CLI
    ├── console_lib.py                 # Console library
    ├── update-firmware.sh             # Firmware updater
    └── recovery-after-fw-update.sh    # Recovery workflow
```

## 📚 Documentation

### context.md - Main Development Guide
Everything you need for Hydra/Vulcano development:
- Docker environment setup
- Build commands (x86 DOL, simulator, firmware)
- Testing workflows (GTest, DOL, P4+, QEMU)
- Firmware update procedure
- Recovery workflow
- nicctl command reference
- Console access

### Hardware Setups
6 documented setups with 48 Vulcano NICs:

**Development/Testing:**
- SMC1 (10.30.75.198) - 8 NICs
- SMC2 (10.30.75.204) - 8 NICs

**800G Leaf-Spine:**
- GT1 (10.30.69.101) - 8 NICs
- GT4 (10.30.69.98) - 8 NICs

**Arista Leaf-Spine:**
- Waco5 (10.30.64.25) - 8 NICs
- Waco6 (10.30.64.26) - 8 NICs

Each setup includes:
- Management & BMC IPs with credentials
- All 8 NICs with console access (Vulcano + SuC)
- Serial numbers, MAC addresses
- Network topology
- Switch configurations

## 🛠️ Automation Scripts

### 1. Firmware Update
```bash
# Automated firmware update
./scripts/update-firmware.sh <setup> <firmware_tar>

# Example
./scripts/update-firmware.sh smc1 /sw/ainic_fw_vulcano.tar

# Does:
# - Copy firmware to host
# - Update firmware (nicctl)
# - Reset cards
# - Verify all cards up
```

### 2. Recovery (Cards Not Coming Up)
```bash
# Automated recovery workflow
./scripts/recovery-after-fw-update.sh <setup>

# Example
./scripts/recovery-after-fw-update.sh smc1

# Does:
# 1. Check version on Vulcano consoles
# 2. Reboot Vulcano via SuC (kernel reboot)
# 3. Reboot host
# 4. Wait for host
# 5. Verify all cards
```

### 3. Console Manager
```bash
# Interact with 96 console connections
./scripts/console-mgr.py --setup <name> --console <type> --all <command>

# Examples
./scripts/console-mgr.py --setup smc1 --console vulcano --all version
./scripts/console-mgr.py --setup smc2 --console suc --all reboot
./scripts/console-mgr.py --setup waco5 --console vulcano --nic ai0 version

# Features:
# - Manages 96 consoles (6 setups × 8 NICs × 2 types)
# - Parallel execution (fast!)
# - Predefined commands
# - Custom command support
# - Automatic line clearing
```

## 🔑 Key Workflows

### Complete Firmware Update Workflow

**Happy Path:**
```bash
# 1. Build
make -f Makefile.build build-rudra-vulcano-hydra-ainic-fw

# 2. Update
~/dev-notes/pensando-sw/scripts/update-firmware.sh smc1 /sw/ainic_fw_vulcano.tar

# 3. Verify
ssh ubuntu@10.30.75.198 'sudo nicctl show card'
```

**Recovery Path (cards don't come up):**
```bash
# Automated
~/dev-notes/pensando-sw/scripts/recovery-after-fw-update.sh smc1

# Or manual
~/dev-notes/pensando-sw/scripts/console-mgr.py --setup smc1 --console vulcano --all version
~/dev-notes/pensando-sw/scripts/console-mgr.py --setup smc1 --console suc --all reboot
ssh ubuntu@10.30.75.198 'sudo reboot'
# Wait 2-3 min
ssh ubuntu@10.30.75.198 'sudo nicctl show card'
```

### Build Workflow

```bash
# Launch Docker
cd /ws/pradeept/ws/usr/src/github.com/pensando/sw/nic
make docker/shell

# Inside Docker
cd /sw
make pull-assets

# Build (choose one)
make -f Makefile.build build-rudra-vulcano-hydra-x86-dol      # Development
make -f Makefile.build build-rudra-vulcano-hydra-ainic-fw     # Firmware
make -f Makefile.build build-rudra-vulcano-hydra-sim          # Simulator
```

### Testing Workflow

```bash
# Run GTest
DMA_MODE=uxdma ASIC=vulcano ./rudra/test/tools/run_gtests.sh --p4_program hydra --bin hydra_gtest

# Run DOL tests
PIPELINE=rudra ASIC=vulcano P4_PROGRAM=hydra PCIEMGR_IF=1 DMA_MODE=uxdma PROFILE=zephyr \
  rudra/test/tools/dol/rundol.sh --pipeline rudra --topo rdma_hydra --feature rdma_hydra --sub rdma_write --nohntap
```

## 📊 Data Format

**YAML Files (Machine-Readable):**
- Structured data for automation
- Easy to parse with Python, yq, Ansible
- Single source of truth

**Markdown Files (Human-Readable):**
- Complete procedures and workflows
- Troubleshooting guides
- Quick reference tables

## 🔧 Prerequisites

```bash
# For console manager and automation
pip3 install pyyaml

# For YAML querying (optional but useful)
# Install yq: https://github.com/mikefarah/yq
```

## 🎯 Common Tasks

### Check Setup Information
```bash
# Get management IP for SMC1
yq '.host.mgmt_ip' hardware/vulcano/data/smc1.yml

# Get console for ai0
yq '.nics[] | select(.id == "ai0")' hardware/vulcano/data/smc1.yml

# List all setups
ls hardware/vulcano/data/*.yml
```

### Console Operations
```bash
# Show version on all Vulcano consoles
./scripts/console-mgr.py --setup smc1 --console vulcano --all version

# Show version on all SuC consoles
./scripts/console-mgr.py --setup smc1 --console suc --all version

# Reboot Vulcano (via SuC - correct way)
./scripts/console-mgr.py --setup smc1 --console suc --all reboot

# Check specific NIC
./scripts/console-mgr.py --setup smc1 --console vulcano --nic ai3 device

# Custom command
./scripts/console-mgr.py --setup smc1 --console vulcano --all --cmd "show device"
```

### Firmware Operations
```bash
# Update firmware
./scripts/update-firmware.sh smc1 /sw/ainic_fw_vulcano.tar

# Recovery if cards don't come up
./scripts/recovery-after-fw-update.sh smc1
```

## 📖 Documentation Files

- **context.md** - Complete development guide (build, test, deploy)
- **FIRMWARE-UPDATE-QUICKREF.md** - Quick reference for firmware updates
- **scripts/README.md** - Automation scripts documentation
- **hardware/README.md** - Hardware setups overview
- **hardware/vulcano/data/README.md** - YAML data usage examples

## 🌐 Multi-Machine Usage

This repository is designed to work across multiple machines:

1. **Push to private Git repo:**
   ```bash
   cd ~/dev-notes
   git remote add origin <your-private-repo-url>
   git push -u origin master
   ```

2. **Clone on other machines:**
   ```bash
   git clone <your-repo-url> ~/dev-notes
   ```

3. **Use in Claude Code sessions:**
   ```
   Just say: "Read my pensando-sw context"
   ```

## 🎓 For New Team Members

1. Clone this repo to `~/dev-notes`
2. Read `context.md` for build workflows
3. Check `hardware/vulcano/<setup>.md` for your hardware
4. Use automation scripts in `scripts/`
5. Refer to quick reference files for common tasks

## 📊 Statistics

- **Setups Documented:** 6 (SMC, GT, Waco)
- **Vulcano NICs:** 48 total
- **Console Connections:** 96 (48 × 2 types)
- **Automation Scripts:** 4
- **Build Commands:** 15+ targets
- **Test Workflows:** 5 types
- **Documentation Files:** 15+

## 🔗 Key Information

- **Main Repository:** /ws/pradeept/ws/usr/src/github.com/pensando/sw
- **Main Branch:** master
- **Current Work:** 1x400g-breakout branch
- **Primary Project:** Hydra (nic/rudra/src/hydra/)
- **ASIC:** Vulcano
- **Pipeline:** rudra
- **Product Family:** ainic

## 📞 Support

For issues or questions:
- Check troubleshooting sections in documentation
- Review hardware setup files for configuration
- Use console manager for debugging
- Collect techsupport: `nicctl techsupport <file>`

---

**Last Updated:** 2026-02-25
**Status:** Active, Production-Ready
**Coverage:** Build, Test, Deploy, Hardware, Console Management
