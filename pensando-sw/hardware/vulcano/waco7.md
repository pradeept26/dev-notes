# Vulcano Setup - Waco7

Part of Waco5-8 cluster connected via Arista leaf-spine network topology.

## Hardware Information

### Host System
- **Hostname:** waco7
- **Management IP:** 10.30.64.27
- **OS:** Ubuntu
- **Credentials:** ubuntu/amd123

### BMC Access
- **BMC IP:** 10.30.64.17
- **Credentials:** admin/PenInfra$
- **Web Interface:** https://10.30.64.17/

### Network Configuration
- **Arista Leaf2 Switch:** 10.30.64.203 (admin/Gr33nTr33s)
- **Switch Connection:** telnet 10.30.64.120 2013
- **Switch Ports:** eth1/1-eth8/1 (Waco7 ai0-ai7)

### Vulcano NICs Overview
- **Total NICs:** 8 (ai0 through ai7)
- **ASIC:** Vulcano
- **Product:** AINIC (AI NIC)

### Shared Storage
- **NFS Mount:** `/mnt/clusterfs` (shared across all Waco setups)

## SSH Access

```bash
# SSH to host
ssh ubuntu@10.30.64.27
# Password: amd123

# BMC access
ssh admin@10.30.64.17
# Password: PenInfra$
```

## Vulcano NICs Configuration

### ai0 - FPR25480004
- **Serial Number:** FPR25480004
- **Vulcano Console:** `telnet 10.30.64.120 2038`
- **SuC Console:** `telnet 10.30.64.120 2039`
- **Switch Port:** Leaf2 eth1/1

### ai1 - FPR2552005B
- **Serial Number:** FPR2552005B
- **Vulcano Console:** `telnet 10.30.64.120 2040`
- **SuC Console:** `telnet 10.30.64.120 2041`
- **Switch Port:** Leaf2 eth1/2

### ai2 - FPR25510006
- **Serial Number:** FPR25510006
- **Vulcano Console:** `telnet 10.30.64.120 2036`
- **SuC Console:** `telnet 10.30.64.120 2037`
- **Switch Port:** Leaf2 eth1/3

### ai3 - FPR25510018
- **Serial Number:** FPR25510018
- **Vulcano Console:** `telnet 10.30.64.120 2034`
- **SuC Console:** `telnet 10.30.64.120 2035`
- **Switch Port:** Leaf2 eth1/4

### ai4 - FPR25520019
- **Serial Number:** FPR25520019
- **Vulcano Console:** `telnet 10.30.64.120 2016`
- **SuC Console:** `telnet 10.30.64.120 2021`
- **Switch Port:** Leaf2 eth1/5

### ai5 - FPR25520011
- **Serial Number:** FPR25520011
- **Vulcano Console:** `telnet 10.30.64.120 2030`
- **SuC Console:** `telnet 10.30.64.120 2031`
- **Switch Port:** Leaf2 eth1/6

### ai6 - FPR25520080
- **Serial Number:** FPR25520080
- **Vulcano Console:** `telnet 10.30.64.120 2017`
- **SuC Console:** `telnet 10.30.64.120 2019`
- **Switch Port:** Leaf2 eth1/7

### ai7 - FPR25510008
- **Serial Number:** FPR25510008
- **Vulcano Console:** `telnet 10.30.64.120 2032`
- **SuC Console:** `telnet 10.30.64.120 2033`
- **Switch Port:** Leaf2 eth1/8

## Console Access

### Quick Console Access Script
```bash
# Using console manager
~/dev-notes/pensando-sw/scripts/console-mgr.py --setup waco7 --console vulcano --all version
~/dev-notes/pensando-sw/scripts/console-mgr.py --setup waco7 --console suc --all reboot
```

### Manual Console Access
```bash
# ai0 (FPR25480004)
telnet 10.30.64.120 2038    # Vulcano console
telnet 10.30.64.120 2039    # SuC console

# ai1 (FPR2552005B)
telnet 10.30.64.120 2040    # Vulcano console
telnet 10.30.64.120 2041    # SuC console

# ai2 (FPR25510006)
telnet 10.30.64.120 2036    # Vulcano console
telnet 10.30.64.120 2037    # SuC console

# ai3 (FPR25510018)
telnet 10.30.64.120 2034    # Vulcano console
telnet 10.30.64.120 2035    # SuC console

# ai4 (FPR25520019)
telnet 10.30.64.120 2016    # Vulcano console
telnet 10.30.64.120 2021    # SuC console

# ai5 (FPR25520011)
telnet 10.30.64.120 2030    # Vulcano console
telnet 10.30.64.120 2031    # SuC console

# ai6 (FPR25520080)
telnet 10.30.64.120 2017    # Vulcano console
telnet 10.30.64.120 2019    # SuC console

# ai7 (FPR25510008)
telnet 10.30.64.120 2032    # Vulcano console
telnet 10.30.64.120 2033    # SuC console
```

## Firmware Update Procedure

### Complete Update Workflow for Waco7

**Prerequisites:**
- Built firmware: `/sw/ainic_fw_vulcano.tar` (from build machine)
- SSH access to Waco7: `ubuntu@10.30.64.27`

**Step 1: Copy Firmware**
```bash
# From build machine (outside Docker)
scp /sw/ainic_fw_vulcano.tar ubuntu@10.30.64.27:/tmp/
```

**Step 2: SSH to Waco7**
```bash
ssh ubuntu@10.30.64.27
# Password: amd123
```

**Step 3: Update Firmware**
```bash
# Update firmware to alternate partition (takes 3-5 minutes)
sudo nicctl update firmware -i /tmp/ainic_fw_vulcano.tar
```

**Step 4: Reset All Cards**
```bash
# Reset all 8 cards to activate new firmware
sudo nicctl reset card --all
```

**Step 5: Verify Update**
```bash
# Check all 8 cards are up
sudo nicctl show card

# Verify firmware version
sudo nicctl show version

# Check RDMA devices
ibv_devices
# Should show: ai0, ai1, ai2, ai3, ai4, ai5, ai6, ai7
```

## Testing Procedures

### Basic Functionality Test
```bash
# Check all 8 devices present
lspci | grep Pensando | wc -l
# Should return: 8

# Check all RDMA devices
ibv_devices
# Should show: ai0-ai7

# Check specific device details
ibv_devinfo -d ai0
```

### Network Connectivity Test
```bash
# Verify connection to Arista Leaf2
ping -c 4 10.30.64.203

# Check if all interfaces are up
ip link show | grep -E "enp|benic"
```

### Cross-Node RDMA Test (Waco7 to Waco5)
```bash
# On Waco7 (server):
ib_write_bw -d ai0 --report_gbits

# On Waco5 (client):
ib_write_bw -d ai0 <waco7_ip> --report_gbits
```

## Quick Reference Table

| NIC | Serial | Switch Port | Vulcano Console | SuC Console |
|-----|--------|-------------|-----------------|-------------|
| ai0 | FPR25480004 | Leaf2 eth1/1 | 10.30.64.120:2038 | 10.30.64.120:2039 |
| ai1 | FPR2552005B | Leaf2 eth1/2 | 10.30.64.120:2040 | 10.30.64.120:2041 |
| ai2 | FPR25510006 | Leaf2 eth1/3 | 10.30.64.120:2036 | 10.30.64.120:2037 |
| ai3 | FPR25510018 | Leaf2 eth1/4 | 10.30.64.120:2034 | 10.30.64.120:2035 |
| ai4 | FPR25520019 | Leaf2 eth1/5 | 10.30.64.120:2016 | 10.30.64.120:2021 |
| ai5 | FPR25520011 | Leaf2 eth1/6 | 10.30.64.120:2030 | 10.30.64.120:2031 |
| ai6 | FPR25520080 | Leaf2 eth1/7 | 10.30.64.120:2017 | 10.30.64.120:2019 |
| ai7 | FPR25510008 | Leaf2 eth1/8 | 10.30.64.120:2032 | 10.30.64.120:2033 |

## Related Setups

- [Waco5](./waco5.md) - Paired with Waco6 on Leaf1
- [Waco6](./waco6.md) - Paired with Waco5 on Leaf1
- [Waco8](./waco8.md) - Paired with Waco7 on Leaf2
- [Waco5-8 Cluster Overview](./waco5-8-overview.md) - Leaf-spine topology

---
**Setup Name:** Waco7
**Management IP:** 10.30.64.27
**BMC IP:** 10.30.64.17
**Last Updated:** 2026-03-16
**Status:** Active
