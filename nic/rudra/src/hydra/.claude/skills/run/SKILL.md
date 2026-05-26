---
name: run
description: Execute commands on all testbed hosts
triggers:
  - run command
  - execute on testbed
  - run on all nodes
  - ssh command
---

# Run Commands Skill

Execute commands on all nodes in a testbed via SSH.

## Usage Examples

- "run 'nicctl show card' on smc12"
- "execute 'dmesg | tail' on waco56"
- "run hostname on all nodes"
- "check uptime on prateek"

## Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| testbed | Yes | Testbed name or path to YAML |
| command | Yes | Command(s) to execute (quote if spaces) |
| -i, --input | No | Input to send to interactive commands |
| -q, --quiet | No | Suppress informational output |
| -s, --stop-on-error | No | Stop on first error |

## Script

```bash
.claude/skills/scripts/testbed/run_commands.sh <testbed.yml> "command" ["command2" ...]
```

## Steps

1. Identify testbed YAML.
2. Parse command(s) from user request.
3. **For read-only queries** (status checks, info gathering): Delegate to a subagent so verbose per-node output stays out of main context. Spawn a `general-purpose` Agent with a self-contained prompt:
   - Tell it which testbed and command(s) to run.
   - Tell it to invoke `.claude/skills/scripts/testbed/run_commands.sh <testbed.yml> "command"`.
   - Ask it to return a **short summary** (under ~100 words): key findings across nodes, any anomalies or per-node differences, exit status. No raw output unless needed to show the specific finding.
4. **For write operations or when user asks for raw output**: Run the script directly in the main context.
5. Relay the agent's summary (or raw output) to the user.

## Common Commands

```bash
# NIC status
"nicctl show card"
"nicctl show port"
"nicctl show firmware"

# Driver status
"lsmod | grep ionic"
"ibv_devinfo"
"dmesg | tail -20"

# System info
"hostname"
"uptime"
"uname -r"
```

## Notes

- Multiple commands run in order on each node
- Use quotes around commands with spaces
- Output is grouped by node
