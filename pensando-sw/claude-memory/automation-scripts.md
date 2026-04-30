# Automation Scripts Reference

## Build/Test/Deploy — Use Repo Skills
Build, test, deploy, and benchmark workflows are now repo skills (from PR #115193).
Use `/build`, `/gtest`, `/dol`, `/deploy`, `/benchmark`, etc.

## Console Manager
**Location:** `~/dev-notes/pensando-sw/.claude/skills/scripts/console/console-mgr.py`
**Skill:** `/console`

### Quick Examples
```bash
# Version check - all Vulcano consoles
~/dev-notes/pensando-sw/.claude/skills/scripts/console/console-mgr.py --setup smc1 --console vulcano --all version

# Reboot Vulcano NICs (via SuC - CORRECT way)
~/dev-notes/pensando-sw/.claude/skills/scripts/console/console-mgr.py --setup smc1 --console suc --all reboot

# Check specific NIC
~/dev-notes/pensando-sw/.claude/skills/scripts/console/console-mgr.py --setup smc1 --console vulcano --nic ai3 status

# Custom command
~/dev-notes/pensando-sw/.claude/skills/scripts/console/console-mgr.py --setup smc1 --console vulcano --all --cmd "free -h"
```

### Key Points
- **NEVER reboot Vulcano console directly** - always use SuC with `kernel reboot`
- Parallel execution by default (fast)
- Auto line-clearing to take console control
- Use `--serial` flag for heavy commands

## Other Private Skills
- `/health-check` — Parallel health check across hosts + NICs for any setup
- `/recover` — Step-by-step recovery when NICs fail after firmware update

## Infrastructure
- `sync-claude-memory.sh` — Git commit/push memory updates
  Location: `~/dev-notes/pensando-sw/.claude/skills/scripts/infra/sync-claude-memory.sh`
