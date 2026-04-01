---
name: dev-notes-complete
description: Complete dev-notes repository structure, automation scripts, and workflows
type: reference
---

# Dev-Notes Repository - Complete Reference

## Repository Location & Structure
- **Path:** `~/dev-notes/pensando-sw/`
- **Purpose:** Centralized documentation, hardware configs, automation scripts for Pensando Hydra/Vulcano development
- **Git-managed:** Yes (synced across multiple machines)

## Key Documentation Files

### Core Guides
- **README.md** - Overview, quick start, statistics (6 setups, 48 NICs, 96 consoles)
- **QUICKSTART.md** - Simplified workflow commands for Claude Code integration
- **ib-testing-guide.md** - Complete IB/RDMA testing guide with MSN validation scenarios
- **FIRMWARE-UPDATE-QUICKREF.md** - Firmware update cheat sheet

### Hardware Documentation
- **hardware/README.md** - Hardware setup overview
- **hardware/vulcano/README.md** - Vulcano-specific documentation
- **hardware/vulcano/smc1.md** - SMC1 detailed configuration (8 NICs, consoles, BMC, switch)
- **hardware/vulcano/smc2.md** - SMC2 detailed configuration
- **hardware/vulcano/data/*.yml** - YAML configurations for automation (smc1, smc2, gt1, gt4, waco1-8, kenya setups)

### Scripts Documentation
- **scripts/README.md** - Complete automation scripts guide with usage examples

## Automation Scripts Directory
**Location:** `~/dev-notes/pensando-sw/scripts/`

### Key Scripts
1. **console-mgr.py** - Console manager CLI (96 consoles across 6 setups)
   - Manages telnet to Vulcano + SuC consoles
   - Parallel execution across all 8 NICs
   - Predefined commands: version, reboot, uptime, status, dmesg, ip
   - Custom command support with `--cmd`

2. **console_lib.py** - Console library (ConsoleSession, ConsoleManager classes)
   - Core functionality for console management
   - Used by console-mgr.py and other automation

3. **update-firmware.sh** - Automated firmware update
   - Reads setup from YAML
   - SCP firmware to host
   - nicctl update + reset + verify

4. **recovery-after-fw-update.sh** - Recovery workflow when cards don't come up
   - Check version on Vulcano consoles
   - Reboot via SuC (kernel reboot)
   - Reboot host
   - Wait and verify

5. **run-ib-test.sh** - IB/RDMA testing wrapper
   - Calls ~/run_ib_bench.py with SMC-specific presets
   - Simplified options for QP count, direction, write modes
   - Excel generation support (--xlsx)

6. **build-hydra.sh** - Build automation with tmux session management

7. **sync-claude-memory.sh** - Auto-commit and push memory changes
   - **CRITICAL:** Run after updating memory files
   - Keeps all machines in sync

8. **deploy-fw-parallel.sh** - Parallel firmware deployment across multiple setups

### Additional Scripts
- check-nfs-mount.sh
- check-waco-health-parallel.sh
- collect-msn-test-results.sh
- collect-rdma-stats.py
- debug-pcie-bandwidth.sh
- fix-smc1-nfs.sh
- msn-validation-suite.py
- parallel-firmware-update.sh
- setup-claude-memory-symlink.sh
- test-console-prompt.py
- verify-console-mapping.py

## YAML Hardware Configuration
**Location:** `~/dev-notes/pensando-sw/hardware/vulcano/data/`

### Structure
Each YAML file contains:
- Host info: mgmt_ip, BMC IP/credentials, switch IP/credentials
- All 8 NICs (ai0-ai7): MAC, serial, interface name, PCIe BDF
- Console info: telnet host/port for Vulcano + SuC consoles
- Network topology: switch ports, IPs

### Available Setups
**Vulcano:**
- smc1.yml, smc2.yml (dev/test, 10.30.75.x)
- gt1.yml, gt2.yml, gt4.yml (800G Leaf-Spine, 10.30.69.x)
- waco1.yml, waco2.yml (Arista Leaf-Spine, 10.30.64.x)
- kenya-*.yml (various test setups)

## IB/RDMA Testing Reference

### Quick Commands (via wrapper)
```bash
# Basic 4 QP test
~/dev-notes/pensando-sw/scripts/run-ib-test.sh smc1-smc2 --qp 4

# MSN context validation (128-entry window stress test)
~/dev-notes/pensando-sw/scripts/run-ib-test.sh smc1-smc2 --qp 1 --max-msg-size 4M --direction bi --iter 2000

# Comprehensive benchmark with Excel
~/dev-notes/pensando-sw/scripts/run-ib-test.sh smc1-smc2 --max-qp 16 --direction both --write-mode both --xlsx
```

### Test Scenarios
1. **Basic Sanity (2 min):** 4 QP, 100 iterations
2. **Out-of-Order Stress (5 min):** 1 QP, 4M messages, bidirectional, 2000 iterations
3. **Multi-QP Scaling (15 min):** Up to 16 QPs, both directions, both write modes, Excel output
4. **RNR Threshold (Advanced):** 1 QP, 8M messages, 5000 iterations, RCN disabled

### Success Indicators
- ✅ Bandwidth > 0 Gb/sec
- ✅ No connection timeouts
- ✅ No excessive RNR NAKs
- ✅ Smooth throughput across QP counts

## Console Operations Reference

### Using console-mgr.py
```bash
# Show version on all Vulcano consoles
~/dev-notes/pensando-sw/scripts/console-mgr.py --setup smc1 --console vulcano --all version

# Reboot all Vulcano NICs (via SuC - correct way)
~/dev-notes/pensando-sw/scripts/console-mgr.py --setup smc1 --console suc --all reboot

# Check specific NIC
~/dev-notes/pensando-sw/scripts/console-mgr.py --setup smc1 --console vulcano --nic ai3 device

# Custom command
~/dev-notes/pensando-sw/scripts/console-mgr.py --setup smc1 --console vulcano --all --cmd "show device"
```

### Console Types
- **vulcano:** Main ASIC console (Zephyr RTOS)
- **suc:** Service & Update Controller console

### Important Rules
- ⚠️ **NEVER reboot Vulcano console directly**
- ✅ Always reboot via SuC console: `kernel reboot`
- Different command syntax: Vulcano uses `show version`, SuC uses `version`

## Firmware Update Workflow

### Using Automation
```bash
# Update firmware
~/dev-notes/pensando-sw/scripts/update-firmware.sh smc1 /sw/ainic_fw_vulcano.tar

# Recovery if cards don't come up
~/dev-notes/pensando-sw/scripts/recovery-after-fw-update.sh smc1
```

### Manual Steps (from build to deployment)
1. Build: `make -f Makefile.build build-rudra-vulcano-hydra-ainic-fw`
2. Copy: `scp /sw/ainic_fw_vulcano.tar ubuntu@10.30.75.198:/tmp/`
3. Update: `sudo nicctl update firmware -i /tmp/ainic_fw_vulcano.tar`
4. Reset: `sudo nicctl reset card --all`
5. Verify: `sudo nicctl show card` and `sudo nicctl show version`

## Integration with Claude Code

### Simplified Commands in QUICKSTART.md
User says → Claude executes:
- "build hw" → Full hardware firmware build in tmux+docker
- "clean hw build" → Clean build from scratch
- "deploy to smc1" → Complete deployment to SMC1
- "run ib test" → Basic 4 QP IB test between SMC1-SMC2
- "test msn window" → MSN context stress test
- "ib benchmark" → Comprehensive test with Excel output

### Automatic Behaviors
- ✅ Uses tmux session `pensando-sw` for builds
- ✅ Manages docker containers
- ✅ Pulls assets when needed
- ✅ Cleans workspace before builds
- ✅ Reports results concisely

## Why This Context Matters

**Before dev-notes:**
- Hardware info scattered across messages, Slack, personal notes
- Manual telnet to 96 consoles
- Inconsistent firmware update procedures
- No automation, no single source of truth

**After dev-notes:**
- Single git repo with complete context
- YAML-driven automation (96 consoles, 6 setups)
- Consistent workflows across all setups
- Claude Code can execute complex multi-step operations with simple commands
- Context persists across machines and Claude sessions

## How to Use in Future Conversations

When the user references dev-notes or asks about:
- Hardware setups → Point to `~/dev-notes/pensando-sw/hardware/vulcano/<setup>.md`
- Automation → Point to `~/dev-notes/pensando-sw/scripts/<script>`
- Workflows → Point to `~/dev-notes/pensando-sw/QUICKSTART.md`
- IB testing → Point to `~/dev-notes/pensando-sw/ib-testing-guide.md`

The repository is designed to be the **single source of truth** for all Pensando Hydra/Vulcano development context.
