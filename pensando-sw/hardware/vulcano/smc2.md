# Vulcano Setup - SMC2

Secondary Vulcano development and testing setup with 8 Vulcano NICs.

## Hardware Information

### Host System
- **Hostname:** SMC2
- **Management IP:** 10.30.75.204
- **OS:** Ubuntu
- **Credentials:** ubuntu/amd123
- **Location:** Lab setup

### Power Management
- **APC IP:** 10.30.69.45
- **APC Ports:** p32, p31, p26, p25, p16, p15
- **Credentials:** apc/apc

### Switch Connection
- **Micas Switch:** 10.30.75.77
- **Credentials:** admin/Micas123

### Vulcano NICs Overview
- **Total NICs:** 8 (ai0 through ai7)
- **ASIC:** Vulcano
- **Interface naming:** benic1p1 through benic8p1

## Access Information

### SSH Access
```bash
# SSH to host
ssh ubuntu@10.30.75.204
# Password: amd123
```

### BMC Access
```bash
# Web interface
https://10.30.69.49/
# Credentials: admin/PenInfra$

# IPMI access
ipmitool -I lanplus -H 10.30.69.49 -U admin -P 'PenInfra$' power status
```

### Power Control (APC)
```bash
# APC web interface
http://10.30.69.45/
# Credentials: apc/apc
# Controlled ports: p32, p31, p26, p25, p16, p15
```

## Vulcano NICs Configuration

### ai0 - benic2p1
- **MAC Address:** 04:90:81:a1:ba:40
- **Interface:** benic2p1
- **Serial Number:** FPR255200B7
- **Switch Port:** eth1/26 (IP: 30.2.2.2)
- **Vulcano Console:** `telnet 10.30.69.42 2011`
- **SuC Console:** `telnet 10.30.69.42 2012`

### ai1 - benic1p1
- **MAC Address:** 04:90:81:8c:7e:88
- **Interface:** benic1p1
- **Serial Number:** FPR25480030
- **Switch Port:** eth1/25 (IP: 30.2.1.2)
- **Vulcano Console:** `telnet 10.30.69.42 2013`
- **SuC Console:** `telnet 10.30.69.42 2014`

### ai2 - benic3p1
- **MAC Address:** 04:90:81:8c:7d:e0
- **Interface:** benic3p1
- **Serial Number:** FPR2548002A
- **Switch Port:** eth1/27 (IP: 30.2.3.2)
- **Vulcano Console:** `telnet 10.30.69.42 2015`
- **SuC Console:** `telnet 10.30.69.42 2016`

### ai3 - benic4p1
- **MAC Address:** 04:90:81:a1:9a:18
- **Interface:** benic4p1
- **Serial Number:** FPR25520038
- **Switch Port:** eth1/28 (IP: 30.2.4.2)
- **Vulcano Console:** `telnet 10.30.69.42 2017`
- **SuC Console:** `telnet 10.30.69.42 2018`

### ai4 - benic6p1
- **MAC Address:** 04:90:81:a1:9b:98
- **Interface:** benic6p1
- **Serial Number:** FPR25520047
- **Switch Port:** eth1/30 (IP: 30.2.6.2)
- **Vulcano Console:** `telnet 10.30.69.178 2010`
- **SuC Console:** `telnet 10.30.69.178 2011`

### ai5 - benic5p1
- **MAC Address:** 04:90:81:8c:7e:28
- **Interface:** benic5p1
- **Serial Number:** FPR2548002D
- **Switch Port:** eth1/29 (IP: 30.2.5.2)
- **Vulcano Console:** `telnet 10.30.69.178 2012`
- **SuC Console:** `telnet 10.30.69.178 2013`

### ai6 - benic7p1
- **MAC Address:** 04:90:81:a1:b8:78
- **Interface:** benic7p1
- **Serial Number:** FPR255200A5
- **Switch Port:** eth1/31 (IP: 30.2.7.2)
- **Vulcano Console:** `telnet 10.30.69.178 2014`
- **SuC Console:** `telnet 10.30.69.178 2015`

### ai7 - benic8p1
- **MAC Address:** 04:90:81:a1:b5:c0
- **Interface:** benic8p1
- **Serial Number:** FPR2552008B
- **Switch Port:** eth1/32 (IP: 30.2.8.2)
- **Vulcano Console:** `telnet 10.30.69.178 2016`
- **SuC Console:** `telnet 10.30.69.178 2017`

## Network Topology
```
[SMC2 Host - 10.30.75.204]
    |
    | PCIe (8 NICs)
    v
[Vulcano Cards: ai0-ai7]
    |
    | 100G Ethernet
    v
[Micas Switch - 10.30.75.77]
    eth1/25-32 (30.2.x.2 subnet)
```

## Console Access

### Quick Console Access
```bash
# ai0 (benic2p1 - FPR255200B7)
telnet 10.30.69.42 2011    # Vulcano console
telnet 10.30.69.42 2012    # SuC console

# ai1 (benic1p1 - FPR25480030)
telnet 10.30.69.42 2013    # Vulcano console
telnet 10.30.69.42 2014    # SuC console

# ai2 (benic3p1 - FPR2548002A)
telnet 10.30.69.42 2015    # Vulcano console
telnet 10.30.69.42 2016    # SuC console

# ai3 (benic4p1 - FPR25520038)
telnet 10.30.69.42 2017    # Vulcano console
telnet 10.30.69.42 2018    # SuC console

# ai4 (benic6p1 - FPR25520047)
telnet 10.30.69.178 2010   # Vulcano console
telnet 10.30.69.178 2011   # SuC console

# ai5 (benic5p1 - FPR2548002D)
telnet 10.30.69.178 2012   # Vulcano console
telnet 10.30.69.178 2013   # SuC console

# ai6 (benic7p1 - FPR255200A5)
telnet 10.30.69.178 2014   # Vulcano console
telnet 10.30.69.178 2015   # SuC console

# ai7 (benic8p1 - FPR2552008B)
telnet 10.30.69.178 2016   # Vulcano console
telnet 10.30.69.178 2017   # SuC console
```

## Firmware Update Procedure

### Using nicctl
```bash
# 1. Copy firmware to host
scp ainic_fw_vulcano.pldmfw ubuntu@10.30.75.204:/tmp/

# 2. SSH to host
ssh ubuntu@10.30.75.204
# Password: amd123

# 3. Flash firmware to specific device
sudo nicctl fwupdate -p /tmp/ainic_fw_vulcano.pldmfw -d <device>
# Or flash to all devices
sudo nicctl fwupdate -p /tmp/ainic_fw_vulcano.pldmfw

# 4. Reboot or reset
sudo reboot
# Or: sudo nicctl reset
```

### Verification
```bash
# Check firmware version on all NICs
nicctl show version

# Check specific device
lspci | grep Pensando

# Verify RDMA devices
ibv_devinfo

# Check all 8 interfaces
ip link show | grep benic
```

## Driver Information

### Installed Drivers
```bash
# Check loaded modules (should see 8 instances)
lsmod | grep ionic

# Driver version
modinfo ionic_rdma
modinfo ionic
modinfo pds_core

# Check all NIC interfaces
ip link show | grep benic
# Should show: benic1p1 through benic8p1
```

### Verify All 8 NICs
```bash
# Check all PCIe devices
lspci | grep Pensando | nl
# Should show 8 devices

# Check all RDMA devices
ibv_devices
# Should show ai0 through ai7
```

## Testing Procedures

### Basic Functionality Test
```bash
# 1. Check all 8 devices present
lspci | grep Pensando | wc -l
# Should return: 8

# 2. Check all RDMA devices
ibv_devices
# Should show: ai0, ai1, ai2, ai3, ai4, ai5, ai6, ai7

# 3. Check specific device details
ibv_devinfo -d ai0
ibv_devinfo -d ai1
# ... etc

# 4. Verify all network interfaces
ip link show | grep benic
# Should show: benic1p1 through benic8p1
```

### Performance Test (Single NIC)
```bash
# Test ai0
ib_write_bw -d ai0 --report_gbits
ib_read_bw -d ai0 --report_gbits

# Test ai1
ib_write_bw -d ai1 --report_gbits
ib_read_bw -d ai1 --report_gbits
```

### Multi-NIC Testing
```bash
# Run tests on all 8 NICs in parallel
for i in {0..7}; do
  ib_write_bw -d ai$i --report_gbits &
done
wait
```

## Common Issues and Solutions

### Issue 1: Device not detected
**Solution:**
```bash
echo 1 > /sys/bus/pci/rescan
dmesg | grep -i pensando
```

### Issue 2: Firmware update failed
**Solution:**
```bash
# Check device state
nicctl show device

# Reset device
sudo nicctl reset

# Check logs
journalctl -xe | grep -i pensando
```

## Debug Information

### Collect Debug Info
```bash
# Collect comprehensive debug data
sudo nicctl techsupport /tmp/techsupport_$(date +%Y%m%d_%H%M%S).tar.gz

# Check logs
journalctl -xe | grep -i pensando
dmesg | grep -i ionic
```

### Debug Tools
```bash
# ASIC monitor
sudo vulcanomon

# Trace utilities
sudo vulaxitrace
sudo vultrace
sudo capview
```

## Quick Reference Table

| NIC | Interface | MAC | Serial | Switch Port | Vulcano Console | SuC Console |
|-----|-----------|-----|--------|-------------|-----------------|-------------|
| ai0 | benic2p1 | 04:90:81:a1:ba:40 | FPR255200B7 | eth1/26 | 10.30.69.42:2011 | 10.30.69.42:2012 |
| ai1 | benic1p1 | 04:90:81:8c:7e:88 | FPR25480030 | eth1/25 | 10.30.69.42:2013 | 10.30.69.42:2014 |
| ai2 | benic3p1 | 04:90:81:8c:7d:e0 | FPR2548002A | eth1/27 | 10.30.69.42:2015 | 10.30.69.42:2016 |
| ai3 | benic4p1 | 04:90:81:a1:9a:18 | FPR25520038 | eth1/28 | 10.30.69.42:2017 | 10.30.69.42:2018 |
| ai4 | benic6p1 | 04:90:81:a1:9b:98 | FPR25520047 | eth1/30 | 10.30.69.178:2010 | 10.30.69.178:2011 |
| ai5 | benic5p1 | 04:90:81:8c:7e:28 | FPR2548002D | eth1/29 | 10.30.69.178:2012 | 10.30.69.178:2013 |
| ai6 | benic7p1 | 04:90:81:a1:b8:78 | FPR255200A5 | eth1/31 | 10.30.69.178:2014 | 10.30.69.178:2015 |
| ai7 | benic8p1 | 04:90:81:a1:b5:c0 | FPR2552008B | eth1/32 | 10.30.69.178:2016 | 10.30.69.178:2017 |

## Notes
- **Total Vulcano NICs:** 8 (ai0 through ai7)
- **Console Access:** Two console servers (10.30.69.42 and 10.30.69.178)
- **SuC Management:** Each Vulcano has its own SuC (System under Control)
- **Switch Subnets:** 30.2.x.2 range (where x = 1-8)
- **Primary Use:** Hydra development and testing

---
**Setup Name:** SMC2
**Management IP:** 10.30.75.204
**BMC IP:** 10.30.69.49
**Last Updated:** 2026-02-25
**Status:** Active
