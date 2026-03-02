# Salina Setup 1

Primary Salina development and testing setup.

## Hardware Information

### Host System
- **Hostname:** TODO: Add hostname
- **IP Address:** TODO: Add IP
- **OS:** TODO: Add OS
- **Kernel:** TODO: Add kernel version
- **Location:** TODO: Add physical location/rack info

### Pensando Card
- **ASIC:** Salina
- **Board Type:** TODO: Add board type (e.g., POLLARA-1Q400P, AI-NIC400-1Q400-P)
- **Board ID:** TODO: Add board ID
- **PCIe Slot:** TODO: Add slot number
- **Serial Number:** TODO: Add S/N

### Current Firmware
- **Version:** TODO: Add current FW version
- **P4 Program:** TODO: Add P4 program (e.g., Pulsar, Quasar)
- **Build:** TODO: Add build number/date
- **Image:** TODO: Add image name

## Access Information

### SSH Access
```bash
# Primary access
ssh TODO_USER@TODO_HOSTNAME

# Or via IP
ssh TODO_USER@TODO_IP
```

### Serial Console
```bash
# TODO: Add serial console details
```

### BMC/IPMI (if applicable)
- **BMC IP:** TODO: Add BMC IP
- **Username:** TODO: Add username

## Network Configuration

### Management Network
- **Interface:** TODO: Add interface
- **IP:** TODO: Add management IP
- **Gateway:** TODO: Add gateway
- **Subnet:** TODO: Add subnet mask

### Data Network
- **Port 0:** TODO: Add port 0 config
- **Port 1:** TODO: Add port 1 config

### Connected Devices
- **Switch:** TODO: Add switch details
- **Peer DUT:** TODO: Add peer device details
- **Test Host:** TODO: Add test host details

## Network Topology
```
TODO: Add network diagram
```

## Firmware Update Procedure

### Using nicctl
```bash
# 1. Copy firmware to host
scp ainic_fw_salina.pldmfw TODO_USER@TODO_HOSTNAME:/tmp/

# 2. SSH to host
ssh TODO_USER@TODO_HOSTNAME

# 3. Flash firmware
sudo nicctl fwupdate -p /tmp/ainic_fw_salina.pldmfw

# 4. Reboot or reset
sudo reboot
```

### Verification
```bash
nicctl show version
nicctl show device
ibv_devinfo
```

## Driver Information

### Installed Drivers
```bash
lsmod | grep ionic
modinfo ionic_rdma
```

## Testing Procedures

### Basic Functionality Test
```bash
lspci | grep Pensando
ibv_devinfo
# TODO: Add test commands
```

### Performance Test
```bash
# TODO: Add performance test commands
```

## Debug Information

### Collect Debug Info
```bash
sudo nicctl techsupport /tmp/techsupport_$(date +%Y%m%d_%H%M%S).tar.gz
journalctl -xe | grep -i pensando
```

### Debug Tools
```bash
sudo salinamon
sudo salaxitrace
sudo saltrace
```

## Notes
- TODO: Add any special notes about this setup
- TODO: Add known issues or quirks
- TODO: Add contact person for this setup

---
**Setup Owner:** TODO: Add owner name/email
**Last Verified:** TODO: Add last verification date
**Status:** TODO: Active/Inactive/Maintenance
