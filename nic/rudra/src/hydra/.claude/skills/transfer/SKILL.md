---
name: transfer
description: Transfer firmware image to testbed hosts
triggers:
  - transfer image
  - copy firmware
  - scp image
  - upload firmware
---

# Transfer Image Skill

Transfer a firmware image file to all hosts in a testbed without updating.

## Usage Examples

- "transfer image to smc12"
- "copy firmware to waco56"
- "upload ainic_fw_vulcano.tar to prateek"

## Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| testbed | Yes | Testbed name or path to YAML |
| image | Yes | Path to firmware image |
| --parallel | No | Transfer to all nodes in parallel |
| -d | No | Custom remote destination (default: /tmp/) |

## Script

Run via `quiet-run.sh` so per-node `scp` progress is logged to
`/tmp/claude-skills/transfer-*.log` instead of dumped into the
conversation. Read the log if a transfer fails on one node and
you need the underlying error.

```bash
.claude/skills/scripts/lib/quiet-run.sh transfer \
  .claude/skills/scripts/deploy/transfer_image.sh <testbed.yml> <image> [options]
```

## Steps

1. Identify testbed and image file
   - Resolve testbed YAML by checking, in order:
     1. The path as given (if it exists)
     2. `/vol/systest/hydra/testbeds/<name>` (appending `.yml` if missing)
   - If neither exists, ask the user where the testbed YAML lives
2. Run transfer script
3. Report transfer success/failure for each node

## Notes

- Default destination is /tmp/ on remote hosts
- Use --parallel for faster multi-node transfer
- Use with deploy --update-only if image is pre-staged
- Default testbed YAML location: `/vol/systest/hydra/testbeds/`
