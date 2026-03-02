# Firmware Partition Switch Procedure

## Overview

Vulcano cards have dual firmware partitions (A and B) that allow switching between different firmware versions without reflashing. This is useful for:
- Testing new firmware while keeping a known-good version available
- Quick rollback if issues are found
- Accessing different firmware versions already flashed to the card

## Partition Architecture

Each Vulcano card has two firmware partitions:
- **Partition A (mainfwa)** - First firmware bank
- **Partition B (mainfwb)** - Second firmware bank

The active partition determines which firmware the card boots from. Each partition can contain a different firmware version.

## Check Current Partition

### From Vulcano Console

```bash
cd ~/dev-notes/pensando-sw
python3 ./scripts/console-mgr.py --setup <setup_name> --console vulcano --nic <nic_id> version

# Check all cards
python3 ./scripts/console-mgr.py --setup <setup_name> --console vulcano --all version
```

Look for:
- `SUC-firmware: mainfwa` = Partition A is active
- `SUC-firmware: mainfwb` = Partition B is active
- `Firmware version: 1.125.0-a-XXX` = Actual firmware build number

### From Host (if cards are detected)

```bash
ssh <user>@<host_ip> 'sudo nicctl show card'
```

The "F/W partition" column shows which partition is currently active (A or B).

## Switch to Alternate Partition

### Single Card

**Step 1: Set next boot partition via Vulcano console**

```bash
cd ~/dev-notes/pensando-sw

# Switch to partition B (fw-b)
python3 ./scripts/console-mgr.py --setup <setup_name> --console vulcano --nic <nic_id> \
  --cmd "debug update firmware --next-boot-image fw-b"

# Switch to partition A (fw-a)
python3 ./scripts/console-mgr.py --setup <setup_name> --console vulcano --nic <nic_id> \
  --cmd "debug update firmware --next-boot-image fw-a"
```

Expected output:
```
SUC boot firmware set to mainfwb  (for fw-b)
SUC boot firmware set to mainfwa  (for fw-a)
```

**Step 2: Reboot via SuC console**

```bash
python3 ./scripts/console-mgr.py --setup <setup_name> --console suc --nic <nic_id> reboot
```

**Step 3: Wait for boot (45-60 seconds)**

```bash
sleep 45
```

**Step 4: Verify the switch**

```bash
python3 ./scripts/console-mgr.py --setup <setup_name> --console vulcano --nic <nic_id> version \
  | grep -E "SUC-firmware|Firmware version"
```

### All Cards in a Setup

**Script to switch all cards:**

```bash
#!/bin/bash
SETUP="smc1"  # or smc2, gt1, etc.
TARGET_PARTITION="fw-b"  # or fw-a

cd ~/dev-notes/pensando-sw

echo "Setting all cards to boot from ${TARGET_PARTITION}..."
for nic in ai0 ai1 ai2 ai3 ai4 ai5 ai6 ai7; do
  echo "  Setting $nic..."
  python3 ./scripts/console-mgr.py --setup ${SETUP} --console vulcano --nic ${nic} \
    --cmd "debug update firmware --next-boot-image ${TARGET_PARTITION}" 2>&1 | grep "SUC boot firmware"
done

echo "Rebooting all cards via SuC..."
python3 ./scripts/console-mgr.py --setup ${SETUP} --console suc --all reboot

echo "Waiting 60 seconds for cards to boot..."
sleep 60

echo "Verifying partition switch..."
python3 ./scripts/console-mgr.py --setup ${SETUP} --console vulcano --all version \
  | grep -E "NIC: ai[0-7]|SUC-firmware|Firmware version"
```

## Complete Example: SMC1 & SMC2 to Partition B

This example shows switching all cards on both SMC1 and SMC2 to partition B (fw-b):

```bash
cd ~/dev-notes/pensando-sw

# SMC1 - Set all cards to fw-b
for nic in ai0 ai1 ai2 ai3 ai4 ai5 ai6 ai7; do
  python3 ./scripts/console-mgr.py --setup smc1 --console vulcano --nic ${nic} \
    --cmd "debug update firmware --next-boot-image fw-b" 2>&1 | grep "SUC boot firmware"
done

# SMC1 - Reboot all via SuC
python3 ./scripts/console-mgr.py --setup smc1 --console suc --all reboot

# SMC2 - Set all cards to fw-b
for nic in ai0 ai1 ai2 ai3 ai4 ai5 ai6 ai7; do
  python3 ./scripts/console-mgr.py --setup smc2 --console vulcano --nic ${nic} \
    --cmd "debug update firmware --next-boot-image fw-b" 2>&1 | grep "SUC boot firmware"
done

# SMC2 - Reboot all via SuC
python3 ./scripts/console-mgr.py --setup smc2 --console suc --all reboot

# Wait for all cards to boot
sleep 60

# Verify SMC1
echo "=== SMC1 Status ==="
python3 ./scripts/console-mgr.py --setup smc1 --console vulcano --all version \
  | grep -E "NIC: ai[0-7]|SUC-firmware|Firmware version"

# Verify SMC2
echo "=== SMC2 Status ==="
python3 ./scripts/console-mgr.py --setup smc2 --console vulcano --all version \
  | grep -E "NIC: ai[0-7]|SUC-firmware|Firmware version"
```

## Host Reboot After Partition Switch

**Important:** When cards are rebooted via SuC without rebooting the host, the host may lose PCIe connection to some cards. After switching partitions, reboot the host to ensure all cards are properly enumerated:

```bash
# Reboot the host
ssh <user>@<host_ip> 'sudo reboot'

# Wait for host to come back (2-3 minutes)
sleep 120

# Verify all cards are detected
ssh <user>@<host_ip> 'sudo nicctl show card'
```

## Troubleshooting

### Card Not Switching Partitions

If a card stays on the same partition after the switch command:

1. **Verify the command was successful:**
   ```bash
   # Should show "SUC boot firmware set to mainfwb" or "mainfwa"
   ```

2. **Check if the card actually rebooted:**
   - Look at the SuC console output for boot messages
   - Check uptime on Vulcano console

3. **Try manual reboot:**
   ```bash
   python3 ./scripts/console-mgr.py --setup <setup> --console suc --nic <nic> reboot
   ```

### Different Firmware Versions on Different Partitions

This is normal. Each partition can contain a different firmware version. Example:
- Partition A: 1.125.0-a-132
- Partition B: 1.125.0-a-133

To update a specific partition, use `nicctl update firmware` from the host (requires host to detect the card).

### Card Not Detected by Host After Partition Switch

**Symptoms:**
- Card accessible via Vulcano console
- Card shows "IPC connection failed" or not listed in `nicctl show card`
- PCIe enumeration issues

**Solution:**
1. Reboot the card via SuC
2. Reboot the host system
3. Wait for full boot cycle
4. Check `sudo nicctl show card` again

If issue persists:
- Try switching to the other partition
- Check PCIe slot/connection
- Collect techsupport: `sudo nicctl techsupport /tmp/debug.tar.gz`

## Best Practices

1. **Always verify current partition before switching:**
   - Check which partition each card is on
   - Note the firmware version on each partition

2. **Document partition contents:**
   - Keep track of which firmware version is in partition A vs B
   - Use partition B for testing, partition A for stable releases

3. **Switch all cards consistently:**
   - Keep all cards in a setup on the same partition when possible
   - Makes troubleshooting easier

4. **Reboot host after partition switches:**
   - Ensures proper PCIe enumeration
   - Clears any IPC connection issues

5. **Test on one card first:**
   - Before switching all cards, test the procedure on a single card
   - Verify functionality before proceeding with others

## Real-World Example: March 2026 Partition Switch

**Scenario:** SMC1 and SMC2 had mixed partitions with different firmware versions. Goal was to get all cards on firmware v133.

**Discovery:**
- Partition A on most cards: v132
- Partition B on most cards: v133
- One card (SMC1 ai7) had v133 on partition A only
- One card (SMC2 ai4) had v132 on both partitions

**Solution:**
1. Switched all cards to partition B (where v133 was available)
2. For cards with v132 on partition B, switched to partition A (had v133)
3. Result: All 16 cards running v133

**Final configuration:**
- SMC1: All 8 cards on partition B with v133
- SMC2: 7 cards on partition B with v133, 1 card (ai4) on partition A with v133

**Time taken:** ~45 minutes for all cards including verification

## Related Documentation

- [Firmware Update Procedure](./FIRMWARE-UPDATE-QUICKREF.md)
- [Recovery After Firmware Update](./scripts/recovery-after-fw-update.sh)
- [Console Manager](./scripts/console-mgr.py)

---
Last updated: 2026-03-02
