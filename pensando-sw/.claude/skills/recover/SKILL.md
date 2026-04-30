---
name: recover
description: "Step-by-step recovery when Vulcano NICs fail after firmware update. Use when user says recover, recovery, card stuck, nic not coming up, card not responding after update, nic stuck after firmware."
---

# Post-Firmware Recovery Skill

Guided recovery procedure when Vulcano NICs don't come up after firmware
update. Follows escalating recovery steps from least to most disruptive.

## Input

The user's arguments are: `$ARGUMENTS`

Parse:
- **Setup name** (required): e.g., `smc1`, `waco5`
- **Host IP** (optional): if known, skip testbed lookup
- **Symptom** (optional): what the user is seeing

If no setup specified, ask the user.

## Prerequisites

- SSH access to the host
- Console access to NICs (console-mgr.py)
- Testbed YAML in `~/dev-notes/pensando-sw/hardware/vulcano/data/`

## Workflow

### Phase 1: Diagnose Current State

SSH to the host and collect status:

```bash
# Check card state
sudo nicctl show card

# Check firmware version
sudo nicctl show version

# Check PCIe devices visible
lspci | grep -i pensando

# Check dmesg for errors
dmesg | tail -50 | grep -i -E 'pensando|ionic|error|fault'
```

Classify the state:
- **Cards visible but not UP** → Go to Phase 2 (soft recovery)
- **Cards not visible in lspci** → Go to Phase 3 (hard recovery)
- **Cards UP but ports down** → Use `/debug-link` skill instead
- **Cards UP and healthy** → No recovery needed

### Phase 2: Soft Recovery (Reset)

Try nicctl reset first (least disruptive):

```bash
# Reset all cards
sudo nicctl reset card --all

# Wait 60-90 seconds for cards to come back
sleep 90

# Check status
sudo nicctl show card
sudo nicctl show version
```

If cards come back UP → **Done**. Run the init/bringup script if one exists:
```bash
# Check testbed YAML for init_script field
# e.g., /mnt/clusterfs/bringup/vulcano_hydra_rccl_bringup.sh
```

If cards still not UP → Go to Phase 3.

### Phase 3: Hard Recovery (Console Reboot)

Reboot NICs via SuC console (power-cycles the NIC):

```bash
~/dev-notes/pensando-sw/.claude/skills/scripts/console/console-mgr.py \
  --setup <SETUP> --console suc --all reboot
```

Wait 2-3 minutes, then check:
```bash
sudo nicctl show card
```

If cards still not UP → Go to Phase 4.

### Phase 4: Host Reboot

Last resort — reboot the host itself:

```bash
sudo reboot
```

Wait for host to come back (3-5 minutes), then:
```bash
sudo nicctl show card
sudo nicctl show version
```

If cards still not UP after host reboot → **Escalate**. Possible causes:
- Firmware corruption (may need gold firmware recovery)
- Hardware failure
- Check `sudo nicctl show card coredump` for crash dumps

### Phase 5: Gold Firmware Recovery (Last Resort)

If the NIC is in a bad firmware state:

```bash
# Check which partition is active
sudo nicctl show card

# Switch to alternate partition
sudo nicctl update firmware --partition-switch

# Reset
sudo nicctl reset card --all
```

If gold firmware also fails → hardware issue, contact support.

## Post-Recovery Checklist

After successful recovery, verify:
1. `sudo nicctl show card` — all cards UP
2. `sudo nicctl show version` — expected firmware version
3. `sudo nicctl show port` — ports UP (if expected)
4. `lspci | grep -i pensando` — all PCIe devices visible
5. `ibstat` — IB devices present and active
6. Run init/bringup script if the testbed YAML specifies one

## Important Notes
- **Always try soft recovery (Phase 2) before hard recovery (Phase 3)**
- **SuC reboot is the correct way to power-cycle a NIC** — not host reboot
- **Gold firmware** is a factory-installed fallback; switching to it loses current firmware
- If multiple NICs in a setup are stuck, they usually all recover together after host reboot
