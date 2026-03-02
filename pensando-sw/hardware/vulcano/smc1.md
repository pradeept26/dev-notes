# Vulcano Setup - SMC1

Primary Vulcano development and testing setup with 8 Vulcano NICs.

## Hardware Information

### Host System
- **Hostname:** SMC1
- **Management IP:** 10.30.75.198
- **OS:** Ubuntu
- **Credentials:** ubuntu/amd123
- **Location:** Lab setup

### Power Management
- **APC IP:** 10.30.69.46
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
ssh ubuntu@10.30.75.198
# Password: amd123
```

### BMC Access
```bash
# Web interface
https://10.30.69.47/
# Credentials: admin/PenInfra$

# IPMI access
ipmitool -I lanplus -H 10.30.69.47 -U admin -P 'PenInfra$' power status
```

### Power Control (APC)
```bash
# APC web interface
http://10.30.69.46/
# Credentials: apc/apc
# Controlled ports: p32, p31, p26, p25, p16, p15
```

## Vulcano NICs Configuration

### ai0 - benic2p1
- **MAC Address:** 04:90:81:a1:b7:a0
- **Interface:** benic2p1
- **Serial Number:** FPR2552009D
- **Switch Port:** eth1/18 (IP: 30.1.1.2)
- **Vulcano Console:** `telnet 10.30.69.42 2003`
- **SuC Console:** `telnet 10.30.69.42 2004`
- **PCIe BDF:** 06:00.0

### ai1 - benic1p1
- **MAC Address:** 04:90:81:8c:7a:50
- **Interface:** benic1p1
- **Serial Number:** FPR25480016
- **Switch Port:** eth1/17 (IP: 30.1.2.2)
- **Vulcano Console:** `telnet 10.30.69.42 2005`
- **SuC Console:** `telnet 10.30.69.42 2006`
- **PCIe BDF:** 06:00.0

### ai2 - benic3p1
- **MAC Address:** 04:90:81:8c:5a:58
- **Interface:** benic3p1
- **Serial Number:** FPR25480003
- **Switch Port:** eth1/19 (IP: 30.1.3.2)
- **Vulcano Console:** `telnet 10.30.69.42 2008`
- **SuC Console:** `telnet 10.30.69.42 2007`

### ai3 - benic4p1
- **MAC Address:** 04:90:81:8c:79:18
- **Interface:** benic4p1
- **Serial Number:** FPR25480010
- **Switch Port:** eth1/20 (IP: 30.1.4.2)
- **Vulcano Console:** `telnet 10.30.69.42 2009`
- **SuC Console:** `telnet 10.30.69.42 2010`

### ai4 - benic6p1
- **MAC Address:** 04:90:81:a1:93:d0
- **Interface:** benic6p1
- **Serial Number:** FPR25520008
- **Switch Port:** eth1/22 (IP: 30.1.6.2)
- **Vulcano Console:** `telnet 10.30.69.178 2002`
- **SuC Console:** `telnet 10.30.69.178 2003`

### ai5 - benic5p1
- **MAC Address:** 04:90:81:a1:9b:20
- **Interface:** benic5p1
- **Serial Number:** FPR25520042
- **Switch Port:** eth1/21 (IP: 30.1.5.2)
- **Vulcano Console:** `telnet 10.30.69.178 2004`
- **SuC Console:** `telnet 10.30.69.178 2005`

### ai6 - benic7p1
- **MAC Address:** 04:90:81:a1:b2:a8
- **Interface:** benic7p1
- **Serial Number:** FPR2552006B
- **Switch Port:** eth1/23 (IP: 30.1.7.2)
- **Vulcano Console:** `telnet 10.30.69.178 2006`
- **SuC Console:** `telnet 10.30.69.178 2007`

### ai7 - benic8p1
- **MAC Address:** 04:90:81:a1:b5:78
- **Interface:** benic8p1
- **Serial Number:** FPR25520088
- **Switch Port:** eth1/24 (IP: 30.1.8.2)
- **Vulcano Console:** `telnet 10.30.69.178 2008`
- **SuC Console:** `telnet 10.30.69.178 2018`

## Network Topology
```
[SMC1 Host - 10.30.75.198]
    |
    | PCIe (8 NICs)
    v
[Vulcano Cards: ai0-ai7]
    |
    | 100G Ethernet
    v
[Micas Switch - 10.30.75.77]
    eth1/17-24 (30.1.x.2 subnet)
```

## Console Access

### Quick Console Access
```bash
# ai0 (benic2p1 - FPR2552009D)
telnet 10.30.69.42 2003    # Vulcano console
telnet 10.30.69.42 2004    # SuC console

# ai1 (benic1p1 - FPR25480016)
telnet 10.30.69.42 2005    # Vulcano console
telnet 10.30.69.42 2006    # SuC console

# ai2 (benic3p1 - FPR25480003)
telnet 10.30.69.42 2008    # Vulcano console
telnet 10.30.69.42 2007    # SuC console

# ai3 (benic4p1 - FPR25480010)
telnet 10.30.69.42 2009    # Vulcano console
telnet 10.30.69.42 2010    # SuC console

# ai4 (benic6p1 - FPR25520008)
telnet 10.30.69.178 2002   # Vulcano console
telnet 10.30.69.178 2003   # SuC console

# ai5 (benic5p1 - FPR25520042)
telnet 10.30.69.178 2004   # Vulcano console
telnet 10.30.69.178 2005   # SuC console

# ai6 (benic7p1 - FPR2552006B)
telnet 10.30.69.178 2006   # Vulcano console
telnet 10.30.69.178 2007   # SuC console

# ai7 (benic8p1 - FPR25520088)
telnet 10.30.69.178 2008   # Vulcano console
telnet 10.30.69.178 2018   # SuC console
```

## Firmware Update Procedure

### Complete Update Workflow for SMC1

**Prerequisites:**
- Built firmware: `/sw/ainic_fw_vulcano.tar` (from build machine)
- SSH access to SMC1: `ubuntu@10.30.75.198`

**Step 1: Copy Firmware**
```bash
# From build machine (outside Docker)
scp /sw/ainic_fw_vulcano.tar ubuntu@10.30.75.198:/tmp/
```

**Step 2: SSH to SMC1**
```bash
ssh ubuntu@10.30.75.198
# Password: amd123
```

**Step 3: Update Firmware**
```bash
# Update firmware to alternate partition (takes 3-5 minutes)
sudo nicctl update firmware -i /tmp/ainic_fw_vulcano.tar

# Watch for progress bar
# On success: No errors displayed
```

**Step 4: Reset All Cards**
```bash
# Reset all 8 cards to activate new firmware
sudo nicctl reset card --all

# This reboots all Vulcano NICs
# Cards will boot from the new firmware partition
```

**Step 5: Run Init Script**
```bash
# IMPORTANT: Run init script after card reset or host reboot
ssh ubuntu@10.30.75.198
/mnt/clusterfs/bringup/vulcano_hydra_rccl_bringup.sh

# This script initializes the cards for use
# Must be run after:
# - Firmware update + card reset
# - Host reboot
# - Card reset
```

**Step 6: Verify Update**
```bash
# Check all 8 cards are up
sudo nicctl show card
# Should show 8 cards: ai0-ai7

# Verify firmware version
sudo nicctl show version

# Check RDMA devices
ibv_devices
# Should show: ai0, ai1, ai2, ai3, ai4, ai5, ai6, ai7

# Check PCIe devices
lspci | grep Pensando | wc -l
# Should return: 8

# Check network interfaces
ip link show | grep benic
# Should show: benic1p1 through benic8p1
```

### Verification (JSON format)
```bash
# Get card status in JSON
sudo nicctl show card -j | jq .

# Get version info in JSON
sudo nicctl show version -j | jq .

# Check specific card
sudo nicctl show card -j | jq '.[] | select(.id == "ai0")'
```

### Troubleshooting
```bash
# If some cards don't come up
sudo nicctl show card
# Check which cards are missing

# Check kernel logs
dmesg | tail -100 | grep -i pensando
journalctl -xe | grep -i ionic

# Collect techsupport
sudo nicctl techsupport /tmp/smc1_techsupport_$(date +%Y%m%d_%H%M%S).tar.gz

# Try resetting specific card
sudo nicctl reset card <card_id>
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

### Driver Installation
```bash
# Install from bundle
tar xvf ainic_bundle_rudra_vulcano_hydra.tar.gz
cd host_sw_pkg
sudo rpm -ivh ionic-rdma-*.rpm  # For RHEL/CentOS
# Or
sudo dpkg -i ionic-rdma-*.deb   # For Ubuntu

# Load drivers
sudo modprobe ionic_rdma
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

### Switch Connectivity Test
```bash
# Ping switch from each interface's subnet
ping -c 4 10.30.75.77  # Micas switch
```

## Common Issues and Solutions

### Issue 1: Device not detected
**Symptom:** `lspci` doesn't show Pensando device

**Solution:**
```bash
# 1. Rescan PCIe
echo 1 > /sys/bus/pci/rescan

# 2. Check kernel logs
dmesg | grep -i pensando

# 3. Power cycle if needed
```

### Issue 2: Firmware update failed
**Symptom:** nicctl fwupdate fails

**Solution:**
```bash
# TODO: Add troubleshooting steps
```

### Issue 3: RDMA device not available
**Symptom:** `ibv_devinfo` shows no devices

**Solution:**
```bash
# TODO: Add troubleshooting steps
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

## Environment Variables
```bash
# TODO: Add any required environment variables
# Example:
# export IONIC_LOG_LEVEL=debug
```

## Quick Reference Table

| NIC | Interface | MAC | Serial | Switch Port | Vulcano Console | SuC Console |
|-----|-----------|-----|--------|-------------|-----------------|-------------|
| ai0 | benic2p1 | 04:90:81:a1:b7:a0 | FPR2552009D | eth1/18 | 10.30.69.42:2003 | 10.30.69.42:2004 |
| ai1 | benic1p1 | 04:90:81:8c:7a:50 | FPR25480016 | eth1/17 | 10.30.69.42:2005 | 10.30.69.42:2006 |
| ai2 | benic3p1 | 04:90:81:8c:5a:58 | FPR25480003 | eth1/19 | 10.30.69.42:2008 | 10.30.69.42:2007 |
| ai3 | benic4p1 | 04:90:81:8c:79:18 | FPR25480010 | eth1/20 | 10.30.69.42:2009 | 10.30.69.42:2010 |
| ai4 | benic6p1 | 04:90:81:a1:93:d0 | FPR25520008 | eth1/22 | 10.30.69.178:2002 | 10.30.69.178:2003 |
| ai5 | benic5p1 | 04:90:81:a1:9b:20 | FPR25520042 | eth1/21 | 10.30.69.178:2004 | 10.30.69.178:2005 |
| ai6 | benic7p1 | 04:90:81:a1:b2:a8 | FPR2552006B | eth1/23 | 10.30.69.178:2006 | 10.30.69.178:2007 |
| ai7 | benic8p1 | 04:90:81:a1:b5:78 | FPR25520088 | eth1/24 | 10.30.69.178:2008 | 10.30.69.178:2018 |

## Notes
- **Total Vulcano NICs:** 8 (ai0 through ai7)
- **Console Access:** Two console servers (10.30.69.42 and 10.30.69.178)
- **SuC Management:** Each Vulcano has its own SuC (System under Control)
- **Switch Subnets:** 30.1.x.2 range (where x = 1-8)
- **Primary Use:** Hydra development and testing

---
**Setup Name:** SMC1
**Management IP:** 10.30.75.198
**BMC IP:** 10.30.69.47
**Last Updated:** 2026-02-25
**Status:** Active
