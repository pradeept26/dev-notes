# Parallel Firmware Update

Fast firmware updates across multiple servers simultaneously.

## Usage

```bash
./parallel-firmware-update.sh <firmware_tar> <setup1> <setup2> ...
```

## Examples

### Update 2 servers (SMC1 and SMC2)
```bash
./parallel-firmware-update.sh /sw/ainic_fw_vulcano.tar smc1 smc2
```

### Update 4 servers (SMC + GT)
```bash
./parallel-firmware-update.sh /sw/ainic_fw_vulcano.tar smc1 smc2 gt1 gt4
```

### Update all 6 servers
```bash
./parallel-firmware-update.sh /sw/ainic_fw_vulcano.tar smc1 smc2 gt1 gt4 waco5 waco6
```

## What It Does

For each setup **in parallel**:

1. ✅ Reads host IP and credentials from YAML
2. ✅ Copies firmware to host
3. ✅ Updates firmware (`nicctl update firmware`)
4. ✅ Resets all cards (`nicctl reset card --all`)
5. ✅ Waits for cards to come back (30s)
6. ✅ Runs init script (if configured in YAML)
7. ✅ Verifies all 8 cards are up
8. ✅ Reports success/failure

## Features

- **Parallel Execution:** All updates run simultaneously
- **Progress Monitoring:** Real-time status updates
- **Individual Logs:** Separate log per system
- **Summary Report:** Success/failure for each system
- **Duration Tracking:** Shows time taken per system
- **Error Handling:** Continues even if one system fails
- **YAML-Driven:** Automatically reads all config from YAML files

## Performance

**Serial (old way):**
```
SMC1 (5 min) → SMC2 (5 min) → GT1 (5 min) → GT4 (5 min) = 20 minutes
```

**Parallel (new way):**
```
SMC1 ─┐
SMC2 ─┤
GT1  ─┼─→ All complete in ~5-6 minutes!
GT4  ─┘
```

**Speedup:** ~4x faster for 4 systems!

## Output Example

```
╔════════════════════════════════════════════════════════════════╗
║  Parallel Firmware Update                                     ║
╚════════════════════════════════════════════════════════════════╝

Firmware: /sw/ainic_fw_vulcano.tar
Setups: smc1 smc2 gt1 gt4
Total: 4 systems

Update firmware on all systems in parallel? (yes/no): yes

[STEP] Starting parallel firmware updates...

[INFO] Launching update for smc1...
[INFO] Launching update for smc2...
[INFO] Launching update for gt1...
[INFO] Launching update for gt4...

[STEP] All updates launched in parallel
[INFO] Monitoring progress...

14:32:15 - Updates in progress...

[STEP] Collecting results...

[INFO] smc1: ✓ SUCCESS (312s)
  Log: /tmp/parallel_fw_update_12345/smc1.log
[INFO] smc2: ✓ SUCCESS (308s)
  Log: /tmp/parallel_fw_update_12345/smc2.log
[INFO] gt1: ✓ SUCCESS (315s)
  Log: /tmp/parallel_fw_update_12345/gt1.log
[INFO] gt4: ✓ SUCCESS (310s)
  Log: /tmp/parallel_fw_update_12345/gt4.log

╔════════════════════════════════════════════════════════════════╗
║  Parallel Firmware Update Complete                            ║
╚════════════════════════════════════════════════════════════════╝

SUMMARY:
--------
smc1       : ✓ SUCCESS (312s)
smc2       : ✓ SUCCESS (308s)
gt1        : ✓ SUCCESS (315s)
gt4        : ✓ SUCCESS (310s)

Total: 4 succeeded, 0 failed out of 4 systems
```

## Error Handling

If a system fails, the script:
- Continues updating other systems
- Marks failed system in summary
- Provides log file location
- Exits with error code at end

**Example with failure:**
```
SUMMARY:
--------
smc1       : ✓ SUCCESS (312s)
smc2       : ✗ FAILED (45s)
gt1        : ✓ SUCCESS (315s)
gt4        : ✓ SUCCESS (310s)

Total: 3 succeeded, 1 failed out of 4 systems

[WARN] Failed updates - check logs:
  cat /tmp/parallel_fw_update_12345/smc2.log
```

## Recovery

If cards don't come up on some systems after parallel update:

```bash
# Check which systems need recovery
./parallel-firmware-update.sh /sw/ainic_fw_vulcano.tar <failed_setup>

# Or use recovery script
./recovery-after-fw-update.sh <failed_setup>
```

## Logs

Each update creates a detailed log showing:
- Copy progress
- Update progress
- Reset status
- Init script output
- Verification results

Logs are saved in: `/tmp/parallel_fw_update_<pid>/`

## Tips

1. **Start with 2 systems** to test (smc1 smc2)
2. **Network bandwidth:** Firmware copies happen simultaneously
3. **Init scripts:** Automatically run if configured in YAML
4. **Recovery:** Use recovery script if cards don't come up
5. **Logs:** Keep logs for debugging if issues occur

## Comparison with Serial Update

| Aspect | Serial | Parallel |
|--------|--------|----------|
| Time for 2 systems | ~10 min | ~5 min |
| Time for 4 systems | ~20 min | ~5-6 min |
| Time for 6 systems | ~30 min | ~5-6 min |
| Network load | Low | Higher (simultaneous copies) |
| Monitoring | Sequential | All at once |
| Debugging | Easier | Check individual logs |

## Prerequisites

- `yq` installed
- `sshpass` installed
- SSH access to all target hosts
- Sufficient network bandwidth for parallel SCP

---

**Created:** 2026-02-26
**Speedup:** 3-6x faster depending on number of systems
**Recommended for:** 2+ systems
