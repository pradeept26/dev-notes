# Hardware Setup Documentation

Documentation for physical hardware setups used for Pensando SW development and testing.

## Available Setups

### Vulcano ASIC
- [SMC1](./vulcano/smc1.md) - Vulcano setup 1
- [SMC2](./vulcano/smc2.md) - Vulcano setup 2
- [Vulcano Overview](./vulcano/README.md)

### Salina ASIC
- [Setup 1](./salina/setup1.md) - Salina setup 1
- [Setup 2](./salina/setup2.md) - Salina setup 2
- [Salina Overview](./salina/README.md)

## Quick Reference

### Common Operations

**Check device status:**
```bash
# From host
lspci | grep Pensando

# Check firmware version
nicctl show version
```

**Flash firmware:**
```bash
# Standard method
nicctl fwupdate -p /path/to/ainic_fw_vulcano.pldmfw

# Or via SCP
scp ainic_fw_vulcano.pldmfw user@device:/tmp/
ssh user@device 'nicctl fwupdate -p /tmp/ainic_fw_vulcano.pldmfw'
```

**RDMA verification:**
```bash
# Check RDMA devices
ibv_devinfo

# Check RDMA connectivity
ibv_devices
```

## Setup Selection Guide

| ASIC | Setup | Use Case | Status |
|------|-------|----------|--------|
| Vulcano | SMC1 | Hydra development | Active |
| Vulcano | SMC2 | Hydra testing | Active |
| Salina | Setup1 | Pulsar development | Active |
| Salina | Setup2 | Pulsar testing | Active |

---
Last updated: 2026-02-25
