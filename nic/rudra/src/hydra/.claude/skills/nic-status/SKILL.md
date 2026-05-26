---
name: nic-status
description: Check NIC status on testbed
triggers:
  - check nic status
  - show nic
  - nic status
  - card status
  - show card
  - check firmware
---

# Check NIC Status Skill

Check NIC card, port, and firmware status on all testbed nodes.

## Usage Examples

- "check nic status on smc12"
- "show cards on waco56"
- "what firmware is on prateek"
- "check port status"

## Commands Run

```bash
# Card info
nicctl show card

# Port info
nicctl show port

# Firmware info
nicctl show firmware

# Driver loaded
lsmod | grep ionic

# RDMA devices
ibv_devinfo
```

## Script

```bash
.claude/skills/scripts/testbed/run_commands.sh <testbed.yml> "nicctl show card"
```

## Steps

1. Identify the testbed YAML (e.g. `~/ws/tools/testbeds/<name>.yml`).
2. Delegate execution to a subagent so the verbose `nicctl` tables stay out of the main context. Spawn a `general-purpose` Agent with a self-contained prompt:
   - Tell it which testbed YAML to use and which commands to run (default: `nicctl show card`; add `show port`, `show firmware`, `ibv_devinfo`, or `lsmod | grep ionic` only if the user asked).
   - Tell it to invoke `.claude/skills/scripts/testbed/run_commands.sh <testbed.yml> "<cmd>"`.
   - Ask it to return a **short summary only** (under ~100 words): per-node card count, any down/missing cards, firmware partition mix, and anything anomalous. No raw tables unless the user explicitly asked for them.
3. Relay the agent's summary to the user.

Only run the script directly in the main context if the user explicitly asks to see raw output.

## Interpreting Output

**nicctl show card:**
- Card ID, serial number, MAC address
- Firmware version
- Card state (up/down)

**nicctl show port:**
- Port state (up/down)
- Link speed
- FEC mode

**ibv_devinfo:**
- RDMA device name
- Port state, MTU
- GID table
