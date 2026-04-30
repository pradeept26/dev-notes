# Workflow Shortcuts and Automation Preferences

## Key Principle
**User wants maximum automation - execute complete workflows without asking questions.**

## Command Mappings → Repo Skills
Build/test/deploy shortcuts now map to repo skills (from PR #115193):

### Builds
- "build hw" | "build firmware" → `/build` skill (fw target)
- "build sim" → `/build` skill (sim target)
- "build gtest" → `/build-gtest` skill

### Testing
- "run gtests" | "test basic" → `/gtest` skill
- "run dol tests" | "test dol" → `/dol` skill
- "run p4 unit tests" → `/p4plus-unit-test` skill

### Deployment
- "deploy to smc1" → `/deploy` skill with testbed YAML
- "transfer firmware" → `/transfer` skill

### Benchmarking
- "run ib test" → `/benchmark` skill
- "compare results" → `/compare` skill

### Console/Health (Private Skills)
- "console version smc1" → `/console` skill
- "health check waco5" → `/health-check` skill
- "recover smc1" → `/recover` skill

## Automation Rules

**Auto-Execute Without Asking:**
- Build workflows (clean docker, launch, build, report)
- Test execution (setup, run, summarize)
- Standard deployments to dev/test systems
- File operations (read, search, analyze)
- Git operations except push

**Ask Before Executing:**
- git push operations
- Production deployments
- Destructive operations (reset --hard, force push, delete)
- Operations affecting shared/remote systems beyond dev/test

## Preferences
- Concise progress updates
- Detailed results only at end
- Parallel execution when possible
- Tmux for all builds (session: pensando-sw)
