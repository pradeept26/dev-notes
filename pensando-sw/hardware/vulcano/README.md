# Vulcano Hardware Setups

Vulcano ASIC based hardware configurations for Hydra (and other P4 programs) development and testing.

## Available Setups

### SMC Setups (Development/Testing)
- **[SMC1](./smc1.md)** - Primary development setup (10.30.75.198)
- **[SMC2](./smc2.md)** - Secondary/testing setup (10.30.75.204)

### Waco Cluster (Arista Leaf-Spine Topology)
- **[Waco5-8 Cluster Overview](./waco5-8-overview.md)** - Complete leaf-spine topology
- **[Waco5](./waco5.md)** - Leaf1 connected (10.30.64.25)
- **[Waco6](./waco6.md)** - Leaf1 connected (10.30.64.26)
- **[Waco7](./waco7.md)** - Leaf2 connected (10.30.64.27)
- **[Waco8](./waco8.md)** - Leaf2 connected (10.30.64.28)

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

## Setup Quick Reference

| Setup | Management IP | Type | NICs | Network |
|-------|--------------|------|------|---------|
| SMC1 | 10.30.75.198 | Dev/Test | 8 | Micas switch |
| SMC2 | 10.30.75.204 | Dev/Test | 8 | Micas switch |
| Waco5 | 10.30.64.25 | Leaf-Spine | 8 | Arista Leaf1 |
| Waco6 | 10.30.64.26 | Leaf-Spine | 8 | Arista Leaf1 |
| Waco7 | 10.30.64.27 | Leaf-Spine | 8 | Arista Leaf2 |
| Waco8 | 10.30.64.28 | Leaf-Spine | 8 | Arista Leaf2 |

---
Last updated: 2026-03-16
