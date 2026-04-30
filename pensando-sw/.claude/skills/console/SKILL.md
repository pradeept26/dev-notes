---
name: console
description: "Manage Vulcano/SuC NIC consoles — version check, reboot, status, custom commands. Use when user says console, manage consoles, check nic console, reboot nic, console command, connect to console, check vulcano version, reboot suc."
---

# Console Management Skill

Manage telnet console connections to Vulcano and SuC NICs across lab setups
using `console-mgr.py`. Supports 96 consoles across 6 Vulcano setups
(8 NICs × 2 console types per setup).

## Input

The user's arguments are: `$ARGUMENTS`

Parse:
- **Setup name** (required): e.g., `smc1`, `smc2`, `waco5`, `waco6`, `waco7`, `waco8`
- **Console type**: `vulcano` (default), `suc`, or `a35`
- **Target**: `--all` (all NICs) or `--nic <id>` (e.g., `ai0`, `ai3`)
- **Operation**: `version`, `reboot`, `status`, or `--cmd "<command>"`

If the user doesn't specify a setup, ask which setup to target.

## Prerequisites

- Python 3 with `telnetlib` (standard library)
- Network access to console server IPs (defined in testbed YAMLs)
- Testbed YAMLs in `~/dev-notes/pensando-sw/hardware/vulcano/data/`

## Script Location

```
~/dev-notes/pensando-sw/.claude/skills/scripts/console/console-mgr.py
```

## Common Operations

### Check firmware version across all NICs
```bash
~/dev-notes/pensando-sw/.claude/skills/scripts/console/console-mgr.py \
  --setup <SETUP> --console vulcano --all version
```

### Reboot NICs (via SuC — the correct way)
```bash
~/dev-notes/pensando-sw/.claude/skills/scripts/console/console-mgr.py \
  --setup <SETUP> --console suc --all reboot
```

### Check status of a specific NIC
```bash
~/dev-notes/pensando-sw/.claude/skills/scripts/console/console-mgr.py \
  --setup <SETUP> --console vulcano --nic ai3 status
```

### Run custom command on all NICs
```bash
~/dev-notes/pensando-sw/.claude/skills/scripts/console/console-mgr.py \
  --setup <SETUP> --console vulcano --all --cmd "cat /proc/version"
```

## Workflow

### Phase 1: Parse Request
1. Identify setup name, console type, target (all vs specific NIC), and operation
2. If missing, ask the user

### Phase 2: Execute
1. Run console-mgr.py with the appropriate flags
2. Capture output (may take 30-60 seconds for --all operations due to serial telnet connections)

### Phase 3: Report
1. Present results in a table: NIC ID | Status | Output
2. Flag any NICs that failed to respond or returned errors

## Available Setups
- `smc1`, `smc2` — SMC Vulcano systems (8 NICs each)
- `waco5`, `waco6`, `waco7`, `waco8` — Waco Vulcano cluster (8 NICs each)

## Console Types
- `vulcano` — Vulcano SoC console (firmware shell, `version`, `status`)
- `suc` — SuC management console (used for `reboot`, power control)
- `a35` — A35 core console (less commonly used)

## Important Notes
- **Always reboot via SuC**, not Vulcano console — SuC controls the power rail
- Operations are serial per NIC (telnet limitation), so `--all` takes ~30-60s
- Console connections auto-timeout after 10s per NIC
