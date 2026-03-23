# Automation Scripts Reference

## Location
All scripts in: `~/dev-notes/pensando-sw/scripts/`

## Console Manager (console-mgr.py)
**Purpose:** Manage 96 console connections across 6 setups (8 NICs × 2 console types)

### Quick Examples
```bash
# Version check - all Vulcano consoles
~/dev-notes/pensando-sw/scripts/console-mgr.py --setup smc1 --console vulcano --all version

# Reboot Vulcano NICs (via SuC - CORRECT way)
~/dev-notes/pensando-sw/scripts/console-mgr.py --setup smc1 --console suc --all reboot

# Check specific NIC
~/dev-notes/pensando-sw/scripts/console-mgr.py --setup smc1 --console vulcano --nic ai3 status

# Custom command
~/dev-notes/pensando-sw/scripts/console-mgr.py --setup smc1 --console vulcano --all --cmd "free -h"
```

### Key Points
- **NEVER reboot Vulcano console directly** - always use SuC with `kernel reboot`
- Parallel execution by default (fast)
- Auto line-clearing to take console control
- Use `--serial` flag for heavy commands

## IB/RDMA Testing (run-ib-test.sh)
**Purpose:** Simplified wrapper for `~/run_ib_bench.py` with SMC presets

### Common Tests
```bash
# Basic 4 QP test (2 mins)
~/dev-notes/pensando-sw/scripts/run-ib-test.sh smc1-smc2 --qp 4

# MSN window stress test (5 mins)
~/dev-notes/pensando-sw/scripts/run-ib-test.sh smc1-smc2 --qp 1 --max-msg-size 4M --direction bi --iter 2000

# Full benchmark with Excel (15 mins)
~/dev-notes/pensando-sw/scripts/run-ib-test.sh smc1-smc2 --max-qp 16 --direction both --write-mode both --xlsx
```

### Test Presets
- `smc1-smc2` - SMC1 server, SMC2 client
- `smc2-smc1` - SMC2 server, SMC1 client
- `smc1-local` - Loopback on SMC1
- `smc2-local` - Loopback on SMC2

### Important Options
- `--qp N` - Single QP count
- `--max-qp N` - Test powers of 2 up to N (e.g., 16 → 1,2,4,8,16)
- `--direction <uni|bi|both>` - Traffic direction
- `--write-mode <write|write_with_imm|both>` - RDMA write variants
- `--xlsx` - Generate Excel with charts
- `--rcn <enable|disable|both>` - RCN congestion control

## Firmware Update (update-firmware.sh)
**Purpose:** Automated firmware deployment

### Usage
```bash
~/dev-notes/pensando-sw/scripts/update-firmware.sh <setup> <firmware_tar>

# Example
~/dev-notes/pensando-sw/scripts/update-firmware.sh smc1 /sw/ainic_fw_vulcano.tar
```

### What It Does
1. Reads setup info from YAML
2. Copies firmware to host
3. Updates via nicctl
4. Resets all cards
5. Verifies all cards come up

## Recovery Workflow (recovery-after-fw-update.sh)
**Purpose:** Recover when cards don't come up after FW update

### Usage
```bash
~/dev-notes/pensando-sw/scripts/recovery-after-fw-update.sh <setup>

# Example
~/dev-notes/pensando-sw/scripts/recovery-after-fw-update.sh smc1
```

### Steps Performed
1. Check version on all Vulcano consoles
2. Reboot Vulcano via SuC (kernel reboot)
3. Reboot host
4. Wait for host to come back
5. Verify all cards are up

## Other Useful Scripts
- `build-hydra.sh` - Launches tmux + docker for builds
- `sync-claude-memory.sh` - Git commit/push memory updates
- `deploy-fw-parallel.sh` - Parallel firmware deployment
- `check-waco-health-parallel.sh` - Health check across setups
