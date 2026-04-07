# Vulcano Setup - Waco8

Part of Waco5-8 cluster connected via Arista leaf-spine network topology.

## Hardware Information

### Host System
- **Hostname:** waco8 (officially "waco 8")
- **Management IP:** 10.30.64.28
- **OS:** Ubuntu
- **Credentials:** ubuntu/amd123

### BMC Access
- **BMC IP:** 10.30.64.18
- **Credentials:** admin/PenInfra$
- **Web Interface:** https://10.30.64.18/

### Network Configuration
- **Arista Leaf2 Switch:** 10.30.64.203 (admin/Gr33nTr33s)
- **Switch Connection:** telnet 10.30.64.120 2013
- **Switch Ports:** eth9/1-eth16/1 (Waco8 ai0-ai7)

### Vulcano NICs Overview
- **Total NICs:** 8 (ai0 through ai7)
- **ASIC:** Vulcano
- **Product:** AINIC (AI NIC)

### Shared Storage
- **NFS Mount:** `/mnt/clusterfs` (shared across all Waco setups)

## SSH Access

```bash
# SSH to host
ssh ubuntu@10.30.64.28
# Password: amd123

# BMC access
ssh admin@10.30.64.18
# Password: PenInfra$
```

## Vulcano NICs Configuration

### ai0 - FPR2552009C
- **Serial Number:** FPR2552009C
- **Vulcano Console:** `telnet 10.30.64.101 2043`
- **SuC Console:** `telnet 10.30.64.101 2044`
- **Switch Port:** Leaf2 eth9/1

### ai1 - FPR25520066
- **Serial Number:** FPR25520066
- **Vulcano Console:** `telnet 10.30.64.101 2046`
- **SuC Console:** `telnet 10.30.64.101 2049`
- **Switch Port:** Leaf2 eth9/2

### ai2 - FPR25480009
- **Serial Number:** FPR25480009
- **Vulcano Console:** `telnet 10.30.64.101 2036`
- **SuC Console:** `telnet 10.30.64.101 2039`
- **Switch Port:** Leaf2 eth9/3

### ai3 - FPR25510013
- **Serial Number:** FPR25510013
- **Vulcano Console:** `telnet 10.30.64.120 2024`
- **SuC Console:** `telnet 10.30.64.101 2003`
- **Switch Port:** Leaf2 eth9/4

### ai4 - FPR2552006D
- **Serial Number:** FPR2552006D
- **Vulcano Console:** `telnet 10.30.64.120 2010`
- **SuC Console:** `telnet 10.30.64.120 2012`
- **Switch Port:** Leaf2 eth9/5

### ai5 - FPR2551000B
- **Serial Number:** FPR2551000B
- **Vulcano Console:** `telnet 10.30.64.120 2018`
- **SuC Console:** `telnet 10.30.64.120 2020`
- **Switch Port:** Leaf2 eth9/6

### ai6 - FPR25520006
- **Serial Number:** FPR25520006
- **Vulcano Console:** `telnet 10.30.64.120 2026`
- **SuC Console:** `telnet 10.30.64.120 2027`
- **Switch Port:** Leaf2 eth9/7

### ai7 - FPR2551000C
- **Serial Number:** FPR2551000C
- **Vulcano Console:** `telnet 10.30.64.120 2028`
- **SuC Console:** `telnet 10.30.64.120 2029`
- **Switch Port:** Leaf2 eth9/8

## Console Access

### Quick Console Access Script
```bash
# Using console manager
~/dev-notes/pensando-sw/scripts/console-mgr.py --setup waco8 --console vulcano --all version
~/dev-notes/pensando-sw/scripts/console-mgr.py --setup waco8 --console suc --all reboot
```

## Firmware Update Procedure

```bash
# Copy firmware
scp /sw/ainic_fw_vulcano.tar ubuntu@10.30.64.28:/tmp/

# SSH and update
ssh ubuntu@10.30.64.28
sudo nicctl update firmware -i /tmp/ainic_fw_vulcano.tar
sudo nicctl reset card --all

# Verify
sudo nicctl show card
sudo nicctl show version
```

## Quick Reference Table

| NIC | Serial | Switch Port | Vulcano Console | SuC Console |
|-----|--------|-------------|-----------------|-------------|
| ai0 | FPR2552009C | Leaf2 eth9/1 | 10.30.64.101:2043 | 10.30.64.101:2044 |
| ai1 | FPR25520066 | Leaf2 eth9/2 | 10.30.64.101:2046 | 10.30.64.101:2049 |
| ai2 | FPR25480009 | Leaf2 eth9/3 | 10.30.64.101:2036 | 10.30.64.101:2039 |
| ai3 | FPR25510013 | Leaf2 eth9/4 | 10.30.64.120:2024 | 10.30.64.101:2003 |
| ai4 | FPR2552006D | Leaf2 eth9/5 | 10.30.64.120:2010 | 10.30.64.120:2012 |
| ai5 | FPR2551000B | Leaf2 eth9/6 | 10.30.64.120:2018 | 10.30.64.120:2020 |
| ai6 | FPR25520006 | Leaf2 eth9/7 | 10.30.64.120:2026 | 10.30.64.120:2027 |
| ai7 | FPR2551000C | Leaf2 eth9/8 | 10.30.64.120:2028 | 10.30.64.120:2029 |

## Related Setups

- [Waco7](./waco7.md) - Paired on same Leaf2
- [Waco5](./waco5.md) - Connected via Leaf1
- [Waco6](./waco6.md) - Connected via Leaf1
- [Waco5-8 Cluster Overview](./waco5-8-overview.md) - Full topology

---
**Setup Name:** Waco8
**Management IP:** 10.30.64.28
**BMC IP:** 10.30.64.18
**Last Updated:** 2026-03-16
**Status:** Active
