# Console Manager & Automation Scripts

Automation scripts for managing Vulcano NICs and their consoles.

## Build Automation Architecture

All build scripts (`build-hydra-*.sh`) share common functionality via `build-common.sh`:
- ✅ **DRY principle**: ~300 lines of shared code extracted to library
- ✅ **Consistent flags**: All scripts support --clean, --skip-submod, --skip-assets, --clean-docker
- ✅ **Uniform behavior**: tmux management, Docker detection, progress monitoring
- ✅ **Easy to extend**: New build types just define build command and output verification

**Common library:** `build-common.sh` (sourced by all build scripts)

## Available Scripts

### 1. build-hydra-gtest.sh - Automated Hydra GTest Build (NEW!)
**Purpose:** Fully automated build from scratch - handles tmux, submodules, docker, assets, build

**One command to do everything:**
```bash
~/dev-notes/pensando-sw/scripts/build-hydra-gtest.sh

# With options
~/dev-notes/pensando-sw/scripts/build-hydra-gtest.sh --clean        # Clean before build
~/dev-notes/pensando-sw/scripts/build-hydra-gtest.sh --skip-submod  # Skip submodule update
~/dev-notes/pensando-sw/scripts/build-hydra-gtest.sh --skip-assets  # Skip pull-assets
~/dev-notes/pensando-sw/scripts/build-hydra-gtest.sh --clean-docker # Clean up Docker containers
```

**What it automates:**
1. Checks/creates tmux session
2. Updates git submodules (skip with `--skip-submod`)
3. Optionally cleans up old Docker containers (use `--clean-docker`)
4. Launches Docker
5. Pulls assets (skip with `--skip-assets`)
6. Builds hydra gtest (15-30 min)

**See:** `~/dev-notes/pensando-sw/testing/hydra-gtest.md` for complete documentation

### 2. run-hydra-gtest.sh - Hydra GTest Test Runner (NEW!)
**Purpose:** Run gtests inside Docker

```bash
# Build (if already in Docker)
~/dev-notes/pensando-sw/scripts/run-hydra-gtest.sh build

# Run specific test
~/dev-notes/pensando-sw/scripts/run-hydra-gtest.sh test resp_rx.invalid_path_id_nak

# Run all tests
~/dev-notes/pensando-sw/scripts/run-hydra-gtest.sh all
```

### 3. build-hydra-firmware.sh - Hydra Firmware Build (NEW!)
**Purpose:** Automate firmware builds for hardware deployment

```bash
~/dev-notes/pensando-sw/scripts/build-hydra-firmware.sh

# With options
~/dev-notes/pensando-sw/scripts/build-hydra-firmware.sh --clean
~/dev-notes/pensando-sw/scripts/build-hydra-firmware.sh --variant m5
```

**See:** `~/dev-notes/pensando-sw/testing/hydra-firmware-build.md`

### 4. build-hydra-dol.sh - Hydra DOL Build (NEW!)
**Purpose:** Automate x86 package builds for DOL testing

```bash
~/dev-notes/pensando-sw/scripts/build-hydra-dol.sh

# With options
~/dev-notes/pensando-sw/scripts/build-hydra-dol.sh --clean
```

**See:** `~/dev-notes/pensando-sw/testing/hydra-dol-testing.md`

### 5. console-mgr.py - Console Manager
**Purpose:** Interact with Vulcano and SuC consoles across all hardware setups

**Features:**
- ✅ Reads console info from YAML automatically
- ✅ Manages telnet connections
- ✅ Clears lines and takes console control
- ✅ Executes commands on single or all consoles
- ✅ Parallel execution (8 consoles simultaneously)
- ✅ Predefined commands (version, reboot, status, etc.)
- ✅ Custom command support

### 6. update-firmware.sh - Firmware Updater
**Purpose:** Automated firmware update workflow

**Features:**
- ✅ Reads setup info from YAML
- ✅ Copies firmware to host
- ✅ Updates firmware using nicctl
- ✅ Resets cards
- ✅ Verifies all cards come back up

## Console Manager Usage

### Prerequisites
```bash
# Install Python dependencies
pip3 install pyyaml

# Optional: Install jq for JSON parsing in shell scripts
sudo apt-get install jq  # Ubuntu/Debian
# Or download from: https://stedolan.github.io/jq/
```

### Basic Examples

```bash
cd ~/dev-notes/pensando-sw/scripts

# Show version from all Vulcano consoles on SMC1
./console-mgr.py --setup smc1 --console vulcano --all version
# Executes: show version (on each Vulcano console)

# Show version from all SuC consoles on SMC1
./console-mgr.py --setup smc1 --console suc --all version
# Executes: version (on each SuC console)

# Reboot all Vulcano NICs via SuC consoles on SMC2
./console-mgr.py --setup smc2 --console suc --all reboot
# Executes: kernel reboot (on each SuC console - reboots Vulcano)

# Show version from specific NIC (ai0)
./console-mgr.py --setup smc1 --console vulcano --nic ai0 version

# Check uptime on all Vulcano consoles
./console-mgr.py --setup waco5 --console vulcano --all uptime

# Show IP config on ai3 SuC console
./console-mgr.py --setup gt1 --console suc --nic ai3 ip
```

### Custom Commands

```bash
# Execute custom command on all consoles
./console-mgr.py --setup smc1 --console vulcano --all --cmd "cat /proc/cpuinfo | grep processor"

# Execute custom command on specific NIC
./console-mgr.py --setup smc1 --console suc --nic ai0 --cmd "ls -la /tmp"

# Don't clear console line (if already in session)
./console-mgr.py --setup smc1 --console vulcano --nic ai0 --cmd "pwd" --no-clear

# Execute serially (slower but safer for heavy commands)
./console-mgr.py --setup smc1 --console vulcano --all status --serial
```

### Predefined Commands

Available commands:

| Command | Vulcano Console | SuC Console | Description |
|---------|----------------|-------------|-------------|
| **version** | `show version` | `version` | Show firmware version |
| **reboot** | ❌ NOT ALLOWED | `kernel reboot` | Reboot Vulcano (via SuC only!) |
| **uptime** | `uptime` | `uptime` | Show system uptime |
| **status** | `show status`, `show device` | `status` | Show device status |
| **device** | `show device` | `show device` | Show device information |
| **dmesg** | `dmesg \| tail -30` | `dmesg \| tail -30` | Show kernel messages |
| **ip** | `ip addr show`, `ip route show` | `ip addr show`, `ip route show` | Network config |
| **help** | `help` | `help` | Console help |

**IMPORTANT:**
- ⚠️ **Never reboot Vulcano console directly** - always use SuC console with `kernel reboot`
- Vulcano and SuC have different command syntax
- `show version` works on Vulcano, `version` works on SuC

## Use Case Examples

### 1. Check Firmware Version on All Cards

```bash
# Check Vulcano firmware version on all SMC1 cards
./console-mgr.py --setup smc1 --console vulcano --all version

# Output shows version from all 8 NICs
```

### 2. Reboot SuC on All Cards

```bash
# Reboot all SuC consoles on SMC2
./console-mgr.py --setup smc2 --console suc --all reboot

# Use case: After SuC firmware update
```

### 3. Check Status After Firmware Update

```bash
# Check all Vulcano consoles are responding
./console-mgr.py --setup waco5 --console vulcano --all uptime

# Check all SuC consoles are responding
./console-mgr.py --setup waco5 --console suc --all uptime
```

### 4. Debug Specific NIC

```bash
# Check logs on ai3 Vulcano console
./console-mgr.py --setup smc1 --console vulcano --nic ai3 dmesg

# Check network config on ai3 SuC
./console-mgr.py --setup smc1 --console suc --nic ai3 ip
```

### 5. Execute Custom Debug Commands

```bash
# Check memory on all Vulcano consoles
./console-mgr.py --setup smc1 --console vulcano --all --cmd "free -h"

# Check temperature on all SuC consoles
./console-mgr.py --setup smc1 --console suc --all --cmd "sensors"

# List processes on specific NIC
./console-mgr.py --setup smc1 --console vulcano --nic ai0 --cmd "ps aux"
```

## Firmware Update Usage

```bash
cd ~/dev-notes/pensando-sw/scripts

# Update firmware on SMC1
./update-firmware.sh smc1 /sw/ainic_fw_vulcano.tar

# Update firmware on Waco5
./update-firmware.sh waco5 /sw/ainic_fw_vulcano.tar

# The script will:
# 1. Show setup info and ask for confirmation
# 2. Copy firmware to host
# 3. Update firmware (3-5 min with progress)
# 4. Reset all cards
# 5. Wait 30s and verify all cards are up
```

## Advanced Usage

### Using Console Manager in Your Scripts

```python
#!/usr/bin/env python3
import sys
from pathlib import Path

# Import the library
sys.path.insert(0, str(Path(__file__).parent))
from console_lib import ConsoleManager

# Initialize
yaml_dir = Path.home() / 'dev-notes' / 'pensando-sw' / 'hardware' / 'vulcano' / 'data'
mgr = ConsoleManager(str(yaml_dir))

# Get console info for specific NIC
host, port = mgr.get_console_info('smc1', 'ai0', 'vulcano')
print(f"ai0 Vulcano console: telnet {host} {port}")

# Execute command on all consoles
results = mgr.execute_on_all('smc1', 'vulcano', ['uname -a'], parallel=True)

# Process results
for result in results:
    nic_id = result['nic_id']
    output = result['outputs'][0]['output']
    print(f"{nic_id}: {output[:50]}...")
```

### Combining with Other Tools

```bash
# Get all console IPs using yq
yq '.nics[].consoles.vulcano.host' \
  ~/dev-notes/pensando-sw/hardware/vulcano/data/smc1.yml | sort -u

# Generate telnet commands for all consoles
yq '.nics[] | "telnet " + .consoles.vulcano.host + " " + (.consoles.vulcano.port | tostring)' \
  ~/dev-notes/pensando-sw/hardware/vulcano/data/smc1.yml
```

### Batch Operations

```bash
# Check version on all setups
for setup in smc1 smc2 gt1 gt4 waco5 waco6; do
  echo "=== $setup ==="
  ./console-mgr.py --setup $setup --console vulcano --nic ai0 version
done

# Reboot all SuC consoles across all setups
for setup in smc1 smc2 waco5 waco6; do
  echo "Rebooting $setup SuC consoles..."
  ./console-mgr.py --setup $setup --console suc --all reboot
done
```

## Troubleshooting

### Console Manager Issues

**Connection timeout:**
```bash
# Some consoles may be slow, try serial mode
./console-mgr.py --setup smc1 --console vulcano --all version --serial
```

**Console already in use:**
```bash
# Clear the line first
./console-mgr.py --setup smc1 --console vulcano --nic ai0 --cmd "~#"
```

**Import errors:**
```bash
# Install dependencies
pip3 install pyyaml

# Check Python version (requires 3.6+)
python3 --version
```

### Firmware Update Issues

**SCP permission denied:**
```bash
# Check SSH credentials in YAML file
yq '.host.credentials' ~/dev-notes/pensando-sw/hardware/vulcano/data/smc1.yml

# Test SSH access manually
ssh ubuntu@10.30.75.198
```

**Cards don't come up:**
```bash
# Check manually on host
ssh ubuntu@10.30.75.198
sudo nicctl show card
sudo nicctl show card -j

# Check specific card
sudo nicctl reset card ai0
```

## Tips

1. **Use parallel mode** (default) for faster execution across all 8 NICs
2. **Clear lines** (default) to take control of potentially-in-use consoles
3. **Start with simple commands** (version, uptime) to test connectivity
4. **Use --nic** for debugging specific NIC issues
5. **Capture output** to files: `./console-mgr.py ... > output.log`

## Files

- **console_lib.py** - Core library (ConsoleSession, ConsoleManager classes)
- **console-mgr.py** - CLI tool (main interface)
- **update-firmware.sh** - Firmware update automation
- **README.md** - This file

## Related Documentation

- `../context.md` - Build and development workflows
- `../hardware/vulcano/data/*.yml` - Setup configurations
- `../hardware/vulcano/*.md` - Hardware documentation
- `../FIRMWARE-UPDATE-QUICKREF.md` - Firmware update quick reference
