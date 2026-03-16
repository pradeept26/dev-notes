# Vulcano Setup - Waco6

Part of Waco5-8 cluster connected via Arista leaf-spine network topology.

## Hardware Information

### Host System
- **Hostname:** waco6 (officially "waco 6")
- **Management IP:** 10.30.64.26
- **OS:** Ubuntu
- **Credentials:** ubuntu/amd123

### BMC Access
- **BMC IP:** 10.30.64.16
- **Credentials:** admin/PenInfra$
- **Web Interface:** https://10.30.64.16/

### Network Configuration
- **Arista Leaf1 Switch:** 10.30.64.201 (admin/Gr33nTr33s)
- **Switch Connection:** telnet 10.30.64.120 2014
- **Switch Ports:** eth9/1-eth16/1 (Waco6 ai0-ai7)

### Vulcano NICs Overview
- **Total NICs:** 8 (ai0 through ai7)
- **ASIC:** Vulcano
- **Product:** AINIC (AI NIC)

### Shared Storage
- **NFS Mount:** `/mnt/clusterfs` (shared across all Waco setups)

## SSH Access

```bash
# SSH to host
ssh ubuntu@10.30.64.26
# Password: amd123

# BMC access
ssh admin@10.30.64.16
# Password: PenInfra$
```

## Vulcano NICs Configuration

### ai0 - FPR25520057
- **Serial Number:** FPR25520057
- **Vulcano Console:** `telnet 10.30.64.199 2014`
- **SuC Console:** `telnet 10.30.64.199 2015`
- **Switch Port:** Leaf1 eth9/1

### ai1 - FPR2552007C
- **Serial Number:** FPR2552007C
- **Vulcano Console:** `telnet 10.30.64.199 2016`
- **SuC Console:** `telnet 10.30.64.199 2017`
- **Switch Port:** Leaf1 eth9/2

### ai2 - FPR255200A6
- **Serial Number:** FPR255200A6
- **Vulcano Console:** `telnet 10.30.64.199 2012`
- **SuC Console:** `telnet 10.30.64.199 2013`
- **Switch Port:** Leaf1 eth9/3

### ai3 - FPR25520056
- **Serial Number:** FPR25520056
- **Vulcano Console:** `telnet 10.30.64.199 2010`
- **SuC Console:** `telnet 10.30.64.199 2011`
- **Switch Port:** Leaf1 eth9/4

### ai4 - FPR2552006A
- **Serial Number:** FPR2552006A
- **Vulcano Console:** `telnet 10.30.64.199 2002`
- **SuC Console:** `telnet 10.30.64.199 2003`
- **Switch Port:** Leaf1 eth9/5

### ai5 - FPR25520095
- **Serial Number:** FPR25520095
- **Vulcano Console:** `telnet 10.30.64.199 2004`
- **SuC Console:** `telnet 10.30.64.199 2005`
- **Switch Port:** Leaf1 eth9/6

### ai6 - FPR25520039
- **Serial Number:** FPR25520039
- **Vulcano Console:** `telnet 10.30.64.199 2006`
- **SuC Console:** `telnet 10.30.64.199 2007`
- **Switch Port:** Leaf1 eth9/7

### ai7 - FPR2552007B
- **Serial Number:** FPR2552007B
- **Vulcano Console:** `telnet 10.30.64.199 2008`
- **SuC Console:** `telnet 10.30.64.199 2009`
- **Switch Port:** Leaf1 eth9/8

## Console Access

### Quick Console Access Script
```bash
# Using console manager
~/dev-notes/pensando-sw/scripts/console-mgr.py --setup waco6 --console vulcano --all version
~/dev-notes/pensando-sw/scripts/console-mgr.py --setup waco6 --console suc --all reboot
```

## Firmware Update Procedure

```bash
# Copy firmware
scp /sw/ainic_fw_vulcano.tar ubuntu@10.30.64.26:/tmp/

# SSH and update
ssh ubuntu@10.30.64.26
sudo nicctl update firmware -i /tmp/ainic_fw_vulcano.tar
sudo nicctl reset card --all

# Verify
sudo nicctl show card
sudo nicctl show version
```

## Quick Reference Table

| NIC | Serial | Switch Port | Vulcano Console | SuC Console |
|-----|--------|-------------|-----------------|-------------|
| ai0 | FPR25520057 | Leaf1 eth9/1 | 10.30.64.199:2014 | 10.30.64.199:2015 |
| ai1 | FPR2552007C | Leaf1 eth9/2 | 10.30.64.199:2016 | 10.30.64.199:2017 |
| ai2 | FPR255200A6 | Leaf1 eth9/3 | 10.30.64.199:2012 | 10.30.64.199:2013 |
| ai3 | FPR25520056 | Leaf1 eth9/4 | 10.30.64.199:2010 | 10.30.64.199:2011 |
| ai4 | FPR2552006A | Leaf1 eth9/5 | 10.30.64.199:2002 | 10.30.64.199:2003 |
| ai5 | FPR25520095 | Leaf1 eth9/6 | 10.30.64.199:2004 | 10.30.64.199:2005 |
| ai6 | FPR25520039 | Leaf1 eth9/7 | 10.30.64.199:2006 | 10.30.64.199:2007 |
| ai7 | FPR2552007B | Leaf1 eth9/8 | 10.30.64.199:2008 | 10.30.64.199:2009 |

## Related Setups

- [Waco5](./waco5.md) - Paired on same Leaf1
- [Waco7](./waco7.md) - Connected via Leaf2
- [Waco8](./waco8.md) - Connected via Leaf2
- [Waco5-8 Cluster Overview](./waco5-8-overview.md) - Full topology

---
**Setup Name:** Waco6
**Management IP:** 10.30.64.26
**BMC IP:** 10.30.64.16
**Last Updated:** 2026-03-16
**Status:** Active
