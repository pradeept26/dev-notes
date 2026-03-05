# Workflow Shortcuts and Automation Preferences

## Key Principle
**User wants maximum automation - execute complete workflows without asking questions.**

## Shorthand Command Mappings

### Builds
- "make vulcano hydra hw build" | "build hw" → Full hardware firmware build workflow
- "make vulcano hydra sim build" | "build sim" → Full sim build workflow
- "build gtest" → GTest-specific build

### Testing
- "run gtests" | "test basic" → Run gtests excluding scale tests
- "run dol tests" | "test dol" → Run DOL test suite

### Deployment
- "deploy to smc1/smc2" → Copy firmware + update + reset + verify
- "deploy to all smc" | "deploy everywhere" → Deploy to both SMC systems

### Git
- "commit changes" | "make commit" → Auto-draft message and commit (don't push)

### IB/RDMA Testing
- "run ib test" | "test ib basic" → Basic 4 QP test SMC1→SMC2
- "test msn window" | "run ib stress" → Stress test for 128 MSN window validation
- "ib benchmark" | "run ib full" → Comprehensive test with Excel output

## Automation Rules

✅ **Auto-Execute Without Asking:**
- Build workflows (clean docker, launch, build, report)
- Test execution (setup, run, summarize)
- Standard deployments to dev/test systems
- File operations (read, search, analyze)
- Git operations except push

⚠️ **Ask Before Executing:**
- git push operations
- Production deployments
- Destructive operations (reset --hard, force push, delete)
- Operations affecting shared/remote systems beyond dev/test

## Implementation Notes

Created CLAUDE.md at project root with full workflow definitions.
User prefers:
- Concise progress updates
- Detailed results only at end
- Parallel execution when possible
- Tmux for all builds (session: pensando-sw)
