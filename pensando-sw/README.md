# Pensando SW Development Notes

Personal development context for Hydra/Vulcano NIC firmware development.
Git-synced across machines via `~/dev-notes`.

## Directory Structure

```
.claude/skills/              Private Claude Code skills
  console/                   Manage Vulcano/SuC NIC consoles
  health-check/              Parallel health check across hosts + NICs
  recover/                   Post-firmware recovery procedure
  scripts/console/           Console manager scripts (console-mgr.py)
  scripts/infra/             Memory sync scripts

hardware/                    Lab testbed inventory
  vulcano/data/*.yml         24 Vulcano testbed YAMLs (SMC, Waco, GT, Kenya)
  vulcano/*.md               Setup documentation
  salina/data/*.yml          7 Salina testbed YAMLs
  salina/*.md                Setup documentation

reference/                   Active reference documents
  ONBOARDING-MAP.md          New engineer onboarding guide
  FIRMWARE-PARTITION-SWITCH.md  Partition A/B switching guide
  HYDRA-AUTOCLEAR-BEHAVIOR.md   TXS autoclear deep dive
  VULCANO-AUTOCLEAR-CHANGES-NEEDED.md  Autoclear design notes
  at_entry_optimization_design_doc.md  AT entry optimization

archive/                     Historical investigations
  nfs-issues/                Resolved NFS mount issues
  gt-bandwidth/              GT bandwidth investigation
  bugs/                      ModifyQP path CC bug analysis

claude-memory/               Claude memory files (synced across machines)
patches/                     Debug patches
```

## Skills

### Repo Skills (shared, from PR #115193)
Build, test, deploy, and benchmark workflows live in the repo at
`nic/rudra/src/hydra/.claude/skills/`. Use `/build`, `/gtest`, `/dol`,
`/deploy`, `/benchmark`, `/connect`, etc.

### Private Skills (this repo)
- `/console` — Manage Vulcano/SuC consoles (version, reboot, status, custom commands)
- `/health-check` — Parallel health check across hosts and NICs for any setup
- `/recover` — Step-by-step recovery when NICs fail after firmware update

## Testbed Inventory

### Vulcano (48 NICs, 96 consoles)
| Setup | Host IP | NICs | Switch |
|-------|---------|------|--------|
| SMC1 | 10.30.75.198 | 8x ai0-ai7 | Micas |
| SMC2 | 10.30.75.204 | 8x ai0-ai7 | Micas |
| Waco5 | 10.30.64.25 | 8x | Arista Leaf1 |
| Waco6 | 10.30.64.26 | 8x | Arista Leaf1 |
| Waco7 | 10.30.64.27 | 8x | Arista Leaf2 |
| Waco8 | 10.30.64.28 | 8x | Arista Leaf2 |

### Salina
Dell-Xeon pairs, Dell-Genoa pair, Purico-Bytedance pairs, Purico-Meta pairs.

## Sync

After updating any file:
```bash
~/dev-notes/pensando-sw/.claude/skills/scripts/infra/sync-claude-memory.sh
```

Pull on another machine:
```bash
cd ~/dev-notes && git pull
```
