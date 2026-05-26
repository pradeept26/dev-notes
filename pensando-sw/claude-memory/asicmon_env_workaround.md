---
name: asicmon env workaround on smc1/smc2 (and possibly other Vulcano nodes)
description: asicmon requires CONFIG_PATH/TMP_DIR/AXITRACE_ROOT env vars and PAL_CARD_UUID scoping; the install profile script is missing on smc1/smc2
type: project
---

When running `asicmon` on smc1 (10.30.75.198) / smc2 (10.30.75.204) — and likely other AINIC hosts where `/etc/profile.d/amd_ainic_user_profile_update.sh` is missing — always export before invoking:

```bash
export CONFIG_PATH=/etc/amd/ainic
export TMP_DIR=/etc/amd/ainic
export AXITRACE_ROOT=/etc/amd/ainic
export PAL_CARD_UUID=<target-card-uuid>   # from `nicctl show card`
sudo -E asicmon ...
```

**Why:** Without CONFIG_PATH, asicmon defaults to `/nic/conf//pipeline.json` which is not part of the standard install (and may be missing — smc2 was, smc1 had a stale 141-byte fallback). Without PAL_CARD_UUID asicmon picks a non-deterministic card on multi-card hosts (8x Vulcano per smc node). Per-card subdirs live under `/etc/amd/ainic/0000:<BDF>/`.

**How to apply:** Any time using debug-datapath skill or running asicmon directly on these nodes, prepend the 4 exports (use `sudo -E` to preserve env across sudo). Also valid alternative if profile.d script exists on the node: `source /etc/profile.d/amd_ainic_user_profile_update.sh`.

**Side-effect:** With proper scoping the asicmon log shrinks ~50% (only the target card is sampled).
