---
name: connect
description: Launch tmux session with SSH to testbed nodes
triggers:
  - connect to testbed
  - ssh to testbed
  - open tmux
  - connect to smc
  - connect to waco
  - tmux session
---

# Connect Testbed Skill

Launch a tmux session with SSH connections to all testbed nodes.

## Usage Examples

- "connect to smc12"
- "open tmux for waco56"
- "connect to prateek with consoles"
- "ssh to all nodes on smc12"

## Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| testbed | Yes | Testbed name or path to YAML |
| -c, --console | No | Include serial console windows |
| -u, --suc | No | Include SUC console windows |
| -d, --dual-ssh | No | Create two SSH windows |
| -y, --sync-panes | No | Synchronize panes (type in all at once) |
| -s, --session-name | No | Custom session name |

## Script

```bash
.claude/skills/scripts/testbed/tmux_testbed.sh <testbed.yml> [options]
```

## Steps

1. Identify testbed YAML
2. Launch tmux session with SSH to each node
3. If -c flag, add console windows for serial access
4. Report session name for user to attach

## Window Layout

- **Window 1 (ssh)**: Split panes with SSH to each node
- **Window 2 (console)**: If -c flag, telnet to serial consoles
- **Window 3 (suc)**: If -u flag, telnet to SUC consoles

## Tmux Tips

```bash
# Attach to session
tmux attach -t <session-name>

# Switch windows
Ctrl-b n    # next window
Ctrl-b p    # previous window

# Switch panes
Ctrl-b o    # cycle panes
Ctrl-b q    # show pane numbers, then press number

# Sync panes (type in all at once)
Ctrl-b :setw synchronize-panes on
```

## Notes

- Session name defaults to testbed name
- Console connections require `console` field in testbed YAML
- Use -C flag to clear console lines before connecting
