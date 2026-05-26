---
name: bringup
description: Wait for NICs after reset and run setup commands
triggers:
  - bringup testbed
  - wait for nics
  - bring up testbed
  - run setup commands
  - wait for reset
---

# Bringup Testbed Skill

Wait for NICs to come back up after reset and run per-node setup commands.

## Usage Examples

- "bringup smc12"
- "wait for NICs on waco56"
- "run setup commands on prateek"

## Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| testbed | Yes | Testbed name or path to YAML |
| --parallel | No | Bring up all hosts in parallel |
| --timeout | No | Custom timeout in seconds (default: 300) |
| --skip-wait | No | Skip NIC wait, just run setup commands |

## Script

Run via `quiet-run.sh` so per-node poll/setup-command output is
logged to `/tmp/claude-skills/bringup-*.log` instead of dumped into
the conversation. Read the log if a single node fails to come up
and you need the polling history.

```bash
.claude/skills/scripts/lib/quiet-run.sh bringup \
  .claude/skills/scripts/deploy/bringup_testbed.sh <testbed.yml> [options]
```

## Steps

1. Identify testbed YAML.
2. Delegate execution to a subagent so per-node polling/setup logs stay out of the main context. Spawn a `general-purpose` Agent with a self-contained prompt:
   - Tell it which testbed and flags to use (--parallel, --timeout, etc.).
   - Tell it to invoke `.claude/skills/scripts/lib/quiet-run.sh bringup .claude/skills/scripts/deploy/bringup_testbed.sh <testbed.yml> [options]`.
   - Ask it to return a **short summary** (under ~100 words): per-node bringup success/failure, any NICs that didn't come up within timeout, setup command results. If all succeeded, just say "N nodes up, setup complete". Include the log file path.
3. Relay the agent's summary to the user.

Only run the bringup script directly in the main context if the user explicitly asks to see detailed polling history or for single-node bringup.

## Setup Commands

Setup commands are defined in testbed YAML:

```yaml
nodes:
  - name: node1
    ip: <NODE_IP>
    setup_commands:
      - "modprobe ionic_rdma"
      - "ibv_devinfo"
```

## Notes

- Default timeout is 5 minutes per node
- Use --parallel for faster multi-node bringup
- Setup commands run in order defined in YAML
