# Parallel Firmware Deployment Script

Fast, parallel firmware deployment to multiple Pensando AINIC systems.

## Quick Start

```bash
# Deploy to SMC1 and SMC2 in parallel (~50% faster than sequential)
~/dev-notes/pensando-sw/scripts/deploy-fw-parallel.sh smc1,smc2 /sw/ainic_fw_vulcano.tar

# Deploy to any combination of systems
~/dev-notes/pensando-sw/scripts/deploy-fw-parallel.sh gt1,gt4,waco5 /sw/ainic_fw_vulcano.tar

# List all available systems
~/dev-notes/pensando-sw/scripts/deploy-fw-parallel.sh --list
```

## Features

- ✅ **Parallel deployment** - Deploy to multiple systems simultaneously
- ✅ **Auto-discovery** - Reads system configs from YAML files (no hardcoding)
- ✅ **25+ systems supported** - All Vulcano and Salina setups
- ✅ **Checksum verification** - Ensures firmware integrity
- ✅ **Color-coded output** - Easy to see success/failure at a glance
- ✅ **Per-system logging** - Detailed logs in `/tmp/deploy-*.log`
- ✅ **Summary report** - Card counts and firmware versions

## System Configuration

Systems are automatically loaded from YAML files in:
- `~/dev-notes/pensando-sw/hardware/vulcano/data/*.yml`
- `~/dev-notes/pensando-sw/hardware/salina/data/*.yml`

The script reads:
- `host.mgmt_ip` - Management IP address
- `credentials.ssh_user` - SSH username (default: ubuntu)
- `credentials.ssh_password` - SSH password (default: amd123)

To add a new system, just create a YAML file in the appropriate directory.

## Performance

| Method | Time (2 systems) | Improvement |
|--------|------------------|-------------|
| Sequential (old) | ~10 min | Baseline |
| Parallel (new) | ~4.5 min | **55% faster** |

For 4+ systems, the parallel deployment is even more efficient.

## Examples

### Deploy to SMC systems
```bash
~/dev-notes/pensando-sw/scripts/deploy-fw-parallel.sh smc1,smc2 /sw/ainic_fw_vulcano.tar
```

### Deploy to GT leaf-spine topology
```bash
~/dev-notes/pensando-sw/scripts/deploy-fw-parallel.sh gt1,gt4 /sw/ainic_fw_vulcano.tar
```

### Deploy to all Waco systems
```bash
~/dev-notes/pensando-sw/scripts/deploy-fw-parallel.sh waco3,waco4,waco5,waco6 /sw/ainic_fw_vulcano.tar
```

### Deploy Salina firmware
```bash
~/dev-notes/pensando-sw/scripts/deploy-fw-parallel.sh dell-xeon-1-2,dell-xeon-3-4 /sw/ainic_fw_salina.tar
```

## Output

The script shows:
1. Real-time progress for each system
2. Checksum verification
3. Firmware update progress
4. Card reset status
5. Final summary with card counts

Detailed logs are saved to `/tmp/deploy-<system>-<pid>.log`

## Troubleshooting

If cards don't come up after firmware update:
- Check logs in `/tmp/deploy-*.log`
- Run recovery script: `~/dev-notes/pensando-sw/scripts/recovery-after-fw-update.sh`
- Check SuC console and host reboot

## Integration with Claude Code

In Claude Code, just say:
- "deploy to all smc"
- "deploy to smc1 and smc2"
- "quick deploy to gt1,gt4"

Claude will automatically use this script without entering plan mode.
