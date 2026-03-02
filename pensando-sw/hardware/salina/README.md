# Salina Hardware Setups

Salina ASIC based hardware configurations for Pulsar, Quasar, and other P4 programs development and testing.

## Available Setups

- **[Setup 1](./setup1.md)** - Primary development setup
- **[Setup 2](./setup2.md)** - Secondary/testing setup

## Salina Overview

**ASIC:** Salina
**Primary P4 Programs:** Pulsar, Quasar, Lynx
**Product Family:** AINIC (AI NIC)

## Common Salina Commands

### Firmware Management
```bash
# Flash firmware
nicctl fwupdate -p /path/to/ainic_fw_salina.pldmfw

# Check firmware version
nicctl show version

# View device info
nicctl show device
```

### Debug Tools
```bash
# ASIC monitor
salinamon

# AXI trace
salaxitrace

# Capture view
capview

# MPU trace
saltrace
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

**Location on build machine:** `/sw/ainic_fw_salina.pldmfw`

**Image types:**
- Standard FW: `ainic_fw_salina.pldmfw`
- Gold FW: `ainic_gold_fw_salina.pldmfw`
- Secure FW: `ainic_fw_salina_secure.pldmfw`

## Network Topology

```
[Host Machine] <--PCIe--> [Salina Card] <--Ethernet--> [Switch/DUT]
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
