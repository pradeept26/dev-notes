# Dev-Notes Reference

## Location
`~/dev-notes/pensando-sw/` - Complete development context repository

## Purpose
Structured documentation and automation for Pensando SW Hydra/Vulcano development
- Hardware setup documentation (6 setups, 48 NICs)
- Automation scripts (console mgr, firmware update, IB testing)
- Build/test/deploy workflows
- Multi-machine sync via Git

## Key Documentation Files

### QUICKSTART.md
Simplified workflow commands for Claude Code sessions:
- "build hw" - Build hardware firmware
- "build sim" - Build simulator
- "deploy to smc1/smc2" - Deploy firmware
- "run ib test" - Run IB/RDMA tests
- "test msn window" - MSN context stress test
- "ib benchmark" - Full benchmark with Excel

### README.md
Repository overview:
- Directory structure
- Statistics (6 setups, 48 NICs, 96 consoles)
- Multi-machine usage instructions
- Quick reference for all workflows

### ib-testing-guide.md
Complete IB/RDMA testing documentation:
- Test scenarios for MSN validation (128-entry window)
- Performance baselines and expectations
- Wrapper script usage (`run-ib-test.sh`)
- Direct script usage (`~/run_ib_bench.py`)
- Result interpretation
- Troubleshooting

### scripts/README.md
Automation scripts documentation:
- console-mgr.py - Console management (96 consoles)
- update-firmware.sh - Automated firmware deployment
- recovery-after-fw-update.sh - Recovery workflow
- run-ib-test.sh - IB test wrapper
- Usage examples and troubleshooting

## Hardware Documentation

### hardware/vulcano/
6 documented setups with complete details:
- smc1.md, smc2.md - Development/testing setups
- gt1.md, gt4.md - 800G Leaf-Spine topology
- waco5.md, waco6.md - Arista Leaf-Spine setups
- data/*.yml - Machine-readable YAML configs

Each setup includes:
- Management & BMC IPs with credentials
- All 8 NICs with console access (Vulcano + SuC)
- Serial numbers, MAC addresses
- Network topology & switch configs

### hardware/salina/
Salina (Pollara) ASIC setups:
- Dell-Xeon paired setups
- Dell-Genoa paired setups
- Purico-Bytedance testbeds
- Purico-Meta RoCE testbeds

## Data Format

### YAML Files (hardware/vulcano/data/*.yml)
Machine-readable structured data for automation:
```yaml
host:
  mgmt_ip: 10.30.75.198
  credentials:
    username: ubuntu
    password: amd123
nics:
  - id: ai0
    consoles:
      vulcano:
        host: 10.30.75.20
        port: 2101
      suc:
        host: 10.30.75.20
        port: 2201
```

Used by:
- console-mgr.py
- update-firmware.sh
- recovery scripts

## Sync Protocol

### Memory Sync
After updating Claude memory:
```bash
~/dev-notes/pensando-sw/scripts/sync-claude-memory.sh
```

This script:
1. Commits memory changes
2. Pushes to Git
3. Syncs across all machines

### Pull Latest on Any Machine
```bash
cd ~/dev-notes && git pull
```

## Integration with Claude Code

### Simplified Commands
Claude recognizes these natural language commands:
- "build hw" → Full firmware build in tmux
- "deploy to smc1" → Automated firmware update
- "run ib test" → Basic IB test (4 QPs)
- "test msn window" → MSN stress test
- "ib benchmark" → Comprehensive test with Excel

### Behind the Scenes
Claude automatically:
- Uses tmux session `pensando-sw`
- Manages docker containers
- Pulls assets when needed
- Cleans workspace before builds
- Runs commands at correct locations
- Reports results concisely

## Current Experiment Context

### MSN Context Reduction (Tracked in QUICKSTART.md)
- Reduced MSN tracking window: 256 → 128 entries
- Memory savings: 50% per QP (2048 → 1024 bytes)
- QP capacity doubled: 1024 → 2048 QPs

Files modified (6):
1. admincmd_handler.c
2. meta_roce_defines.p4
3. rdma_rqcb.p4
4. rdma_sqcb.p4
5. meta_roce_rx_s5.p4
6. meta_roce_tx_s5.p4

## Statistics
- Setups documented: 6 (Vulcano) + multiple (Salina)
- Vulcano NICs: 48 total
- Console connections: 96 (48 × 2 types)
- Automation scripts: 10+
- Build commands: 15+ targets
- Test workflows: 5 types
- Documentation files: 20+

## Key Insights

### Why This Structure Works
1. **Separation of concerns**: Code in `/ws/.../sw`, docs in `~/dev-notes`
2. **Machine-readable + Human-readable**: YAML for automation, Markdown for reading
3. **Git-based sync**: Works across multiple machines
4. **Single source of truth**: YAML drives all automation
5. **Claude-friendly**: Natural language commands mapped to complex workflows

### Usage Pattern
1. Developer works on code in `/ws/.../sw`
2. Refers to `~/dev-notes` for commands/setups
3. Uses automation scripts for repetitive tasks
4. Claude loads context from dev-notes
5. Claude executes complex workflows automatically
6. Memory syncs via Git across machines
