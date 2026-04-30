# Dev-Notes Reference

## Location
`~/dev-notes/pensando-sw/` - Personal development context repository

## Structure (as of 2026-04-30)
```
~/dev-notes/pensando-sw/
├── .claude/skills/          # Private skills (console, health-check, recover)
├── hardware/                # Testbed YAMLs and setup docs (Vulcano + Salina)
├── reference/               # Active reference docs (onboarding, autoclear, etc.)
├── archive/                 # Historical investigations (NFS, GT-bandwidth, bugs)
├── claude-memory/           # Claude memory files (git-synced)
└── patches/                 # Debug patches
```

## Build/Test/Deploy
Build, test, and deploy workflows are now **repo skills** (from PR #115193).
Use: `/build`, `/gtest`, `/dol`, `/deploy`, `/benchmark`, `/connect`, etc.

## Private Skills
Located in `.claude/skills/`, symlinked into workspace for auto-discovery:
- `/console` — Manage Vulcano/SuC consoles
- `/health-check` — Parallel health check across hosts + NICs
- `/recover` — Post-firmware recovery procedure

## Hardware Documentation
### Vulcano (hardware/vulcano/)
- Setup docs: smc1.md, smc2.md, waco5-8 docs
- Data YAMLs: 24 files (smc, waco, gt, kenya configs)
- Each YAML: host IP, credentials, NICs, consoles, switch, power

### Salina (hardware/salina/)
- Dell-Xeon pairs, Dell-Genoa pair, Purico-Bytedance/Meta pairs

## Sync Protocol
```bash
~/dev-notes/pensando-sw/.claude/skills/scripts/infra/sync-claude-memory.sh
```

## Key Insight
- **Repo skills** handle: build, test, deploy, benchmark, debug (shared, in git)
- **Private skills** handle: console management, health checks, recovery (personal, in dev-notes)
- **Hardware YAMLs** drive automation for both (testbed topology definitions)
