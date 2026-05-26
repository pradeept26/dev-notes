---
name: pull-assets
description: Pull build assets from minio
triggers:
  - pull assets
  - get assets
  - download assets
  - pull dependencies
---

# Pull Assets Skill

Pull pre-compiled dependencies and toolchains from minio asset server.

## Usage Examples

- "pull assets for hydra hw"
- "pull vulcano hydra assets"
- "get build assets for simulation"

## Parameters

| Parameter | Options | Default |
|-----------|---------|---------|
| asic | vulcano, salina | vulcano |
| p4_program | hydra, pulsar | hydra |
| platform | hw, sim, sw-emu, emu | hw |

## Script

Run via `quiet-run.sh` so the verbose `make`/`wsctl` output is logged
to `/tmp/claude-skills/pull-assets-*.log` instead of dumped into the
conversation. Read the log file if you need full output.

```bash
.claude/skills/scripts/lib/quiet-run.sh pull-assets \
  .claude/skills/scripts/build/pull-assets.sh <asic> <p4_program> [platform]
```

## Steps

1. Parse user request to identify asic, p4_program, platform
2. Run pull-assets script (auto-detects Docker container)
3. Report completion

## Notes

- Must be run before first build
- Assets are cached in `minio/` directory after first pull
- Different platforms may require different assets (sim vs hw)
- Script auto-detects Docker container
