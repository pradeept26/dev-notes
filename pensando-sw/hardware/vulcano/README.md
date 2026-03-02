# Vulcano Hardware Setups

Vulcano ASIC based hardware configurations for Hydra (and other P4 programs) development and testing.

## Available Setups

- **[SMC1](./smc1.md)** - Primary development setup
- **[SMC2](./smc2.md)** - Secondary/testing setup

## Vulcano Overview

**ASIC:** Vulcano
**Primary P4 Programs:** Hydra, Pulsar, Quasar
**Product Family:** AINIC (AI NIC)

## Common Vulcano Commands

### Firmware Management
```bash
# Flash firmware
nicctl fwupdate -p /path/to/ainic_fw_vulcano.pldmfw

# Check firmware version
nicctl show version

# View device info
nicctl show device
```

### Debug Tools
```bash
# ASIC monitor
vulcanomon

# AXI trace
vulaxitrace

# Capture view
capview

# MPU trace
vultrace
```

### RDMA Operations
```bash
# List RDMA devices
ibv_devinfo

# Show device attributes
ibv_devinfo -v

# Run perftest
ib_write_bw -d <device>
```

## Firmware Images

**Location on build machine:** `/sw/ainic_fw_vulcano.pldmfw`

**Image types:**
- Standard FW: `ainic_fw_vulcano.pldmfw`
- Gold FW: `ainic_gold_fw_vulcano.pldmfw`
- Secure FW: `ainic_fw_vulcano_secure.pldmfw`

## Network Topology

```
[Host Machine] <--PCIe--> [Vulcano Card] <--Ethernet--> [Switch/DUT]
```

## Troubleshooting

### Device not detected
```bash
# Rescan PCIe bus
echo 1 > /sys/bus/pci/rescan

# Check kernel logs
dmesg | tail -50

# Check PCIe link
lspci -vvv | grep -A 20 Pensando
```

### Firmware update failed
```bash
# Check device state
nicctl show device

# Reset device
nicctl reset

# Check logs
journalctl -xe | grep -i pensando
```

---
Last updated: 2026-02-25
