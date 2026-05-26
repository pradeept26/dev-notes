---
name: deploy
description: Deploy firmware to a testbed
triggers:
  - deploy firmware
  - deploy to testbed
  - flash firmware
  - update firmware
  - deploy hydra
  - deploy to smc
  - deploy to waco
---

# Deploy Firmware Skill

Deploy AINIC firmware to a testbed with optional NIC reset.

## Usage Examples

- "deploy hydra to smc12"
- "deploy firmware to waco56 with reset"
- "deploy ~/ws/sw/ainic_fw_vulcano.tar to prateek testbed"
- "deploy and reset smc12"

## Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| testbed | Yes | Testbed name (smc12, waco56, etc.) or path to YAML |
| tarball | No | Path to firmware tarball (default: latest build) |
| --reset | No | Reset NICs after update |
| --parallel | No | Deploy to all nodes in parallel |
| --transfer-only | No | Only transfer, don't update |
| --update-only | No | Image already on remote, just update |
| --reset-only | No | Only reset NICs, no transfer or update |

## Script

Run via `quiet-run.sh` so per-node transfer/update progress is
logged to `/tmp/claude-skills/deploy-*.log` instead of dumped into
the conversation. Tail-on-failure shows enough context to diagnose
a single bad node; Read the log for the full per-node breakdown.

```bash
.claude/skills/scripts/lib/quiet-run.sh deploy \
  .claude/skills/scripts/deploy/deploy_firmware.sh <testbed.yml> [tarball] [options]
```

## Steps

1. Identify testbed YAML (check testbeds/ directory).
2. Identify firmware tarball (ask if not specified, suggest latest build).
3. **Always pass `--parallel` and `--reset`** unless the user explicitly says otherwise. Firmware update is ~5 min per NIC; sequential needlessly doubles wall time. A deploy without reset leaves the old firmware running, which is almost never what the user wants.
4. Delegate execution to a subagent so per-node transfer/update/reset logs stay out of the main context. Spawn a `general-purpose` Agent with a self-contained prompt:
   - Tell it which testbed, tarball, and flags to use (--parallel and --reset by default, plus --interface, etc. as requested).
   - Remind it that after `--reset`, NICs need ~1-2 min to come back; the bringup skill should be run separately if the user wants verification.
   - Tell it to invoke `.claude/skills/scripts/lib/quiet-run.sh deploy .claude/skills/scripts/deploy/deploy_firmware.sh <testbed.yml> [tarball] [options]`.
   - Ask it to return a **short summary** (under ~100 words): per-node success/failure status, any errors encountered, whether NICs were reset. If all succeeded, just say "deployed to N nodes". Include the log file path.
5. Relay the agent's summary to the user.

Only run the deploy script directly in the main context if the user explicitly asks to see detailed per-node logs or for single-node deploys.

## Default Firmware Location

```
~/ws/sw/ainic_fw_vulcano.tar
```

Or build output at:
```
~/ws/sw/nic/build/riscv/sim/rudra/hydra/vulcano/out/images/ainic_fw_vulcano.tar
```

## Full Deploy Workflow

For a complete deploy with reset and bringup:

```bash
.claude/skills/scripts/lib/quiet-run.sh deploy \
  .claude/skills/scripts/deploy/deploy_firmware.sh testbeds/smc12.yml ./ainic_fw_vulcano.tar --reset --parallel
.claude/skills/scripts/lib/quiet-run.sh bringup \
  .claude/skills/scripts/deploy/bringup_testbed.sh testbeds/smc12.yml --parallel
```

## Notes

- **Default to `--parallel --reset`**. Sequential is roughly N× slower; skipping reset leaves the old firmware running on the NIC.
- Reset takes 1-2 minutes for NICs to come back
- After reset, run bringup skill to wait for NICs and run setup commands
