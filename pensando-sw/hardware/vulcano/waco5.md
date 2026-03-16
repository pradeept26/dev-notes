# Vulcano Setup - Waco5

Part of Waco5-8 cluster connected via Arista leaf-spine network topology.

## Hardware Information

### Host System
- **Hostname:** Waco5 (officially "Waco 5")
- **Management IP:** 10.30.64.25
- **OS:** Ubuntu
- **Credentials:** ubuntu/amd123

### BMC Access
- **BMC IP:** 10.30.64.15
- **Credentials:** root/Pen1nfra$
- **Web Interface:** https://10.30.64.15/

### Network Configuration
- **Arista Leaf1 Switch:** 10.30.64.201 (admin/Gr33nTr33s)
- **Switch Connection:** telnet 10.30.64.120 2014
- **Switch Ports:** eth1/1-eth8/1 (Waco5 ai0-ai7)

### Vulcano NICs Overview
- **Total NICs:** 8 (ai0 through ai7)
- **ASIC:** Vulcano
- **Product:** AINIC (AI NIC)

### Shared Storage
- **NFS Mount:** `/mnt/clusterfs` (shared across all Waco setups)

## SSH Access

```bash
# SSH to host
ssh ubuntu@10.30.64.25
# Password: amd123

# BMC access
ssh root@10.30.64.15
# Password: Pen1nfra$
```

## Vulcano NICs Configuration

### ai0 - FPR25510017
- **Serial Number:** FPR25510017
- **Vulcano Console:** `telnet 10.30.64.199 2030`
- **SuC Console:** `telnet 10.30.64.199 2031`
- **Switch Port:** Leaf1 eth1/1

### ai1 - FPR255200A4
- **Serial Number:** FPR255200A4
- **Vulcano Console:** `telnet 10.30.64.199 2032`
- **SuC Console:** `telnet 10.30.64.199 2033`
- **Switch Port:** Leaf1 eth1/2

### ai2 - FPR25520036
- **Serial Number:** FPR25520036
- **Vulcano Console:** `telnet 10.30.64.199 2028`
- **SuC Console:** `telnet 10.30.64.199 2029`
- **Switch Port:** Leaf1 eth1/3

### ai3 - FPR25520064
- **Serial Number:** FPR25520064
- **Vulcano Console:** `telnet 10.30.64.199 2026`
- **SuC Console:** `telnet 10.30.64.199 2027`
- **Switch Port:** Leaf1 eth1/4

### ai4 - FPR25520098
- **Serial Number:** FPR25520098
- **Vulcano Console:** `telnet 10.30.64.199 2018`
- **SuC Console:** `telnet 10.30.64.199 2019`
- **Switch Port:** Leaf1 eth1/5

### ai5 - FPR25520086
- **Serial Number:** FPR25520086
- **Vulcano Console:** `telnet 10.30.64.199 2020`
- **SuC Console:** `telnet 10.30.64.199 2021`
- **Switch Port:** Leaf1 eth1/6

### ai6 - FPR2552000E
- **Serial Number:** FPR2552000E
- **Vulcano Console:** `telnet 10.30.64.199 2022`
- **SuC Console:** `telnet 10.30.64.199 2023`
- **Switch Port:** Leaf1 eth1/7

### ai7 - FPR25520021
- **Serial Number:** FPR25520021
- **Vulcano Console:** `telnet 10.30.64.199 2024`
- **SuC Console:** `telnet 10.30.64.199 2025`
- **Switch Port:** Leaf1 eth1/8

## Console Access

### Quick Console Access Script
```bash
# Using console manager
~/dev-notes/pensando-sw/scripts/console-mgr.py --setup waco5 --console vulcano --all version
~/dev-notes/pensando-sw/scripts/console-mgr.py --setup waco5 --console suc --all reboot
```

## Firmware Update Procedure

```bash
# Copy firmware
scp /sw/ainic_fw_vulcano.tar ubuntu@10.30.64.25:/tmp/

# SSH and update
ssh ubuntu@10.30.64.25
sudo nicctl update firmware -i /tmp/ainic_fw_vulcano.tar
sudo nicctl reset card --all

# Verify
sudo nicctl show card
sudo nicctl show version
```

## Quick Reference Table

| NIC | Serial | Switch Port | Vulcano Console | SuC Console |
|-----|--------|-------------|-----------------|-------------|
| ai0 | FPR25510017 | Leaf1 eth1/1 | 10.30.64.199:2030 | 10.30.64.199:2031 |
| ai1 | FPR255200A4 | Leaf1 eth1/2 | 10.30.64.199:2032 | 10.30.64.199:2033 |
| ai2 | FPR25520036 | Leaf1 eth1/3 | 10.30.64.199:2028 | 10.30.64.199:2029 |
| ai3 | FPR25520064 | Leaf1 eth1/4 | 10.30.64.199:2026 | 10.30.64.199:2027 |
| ai4 | FPR25520098 | Leaf1 eth1/5 | 10.30.64.199:2018 | 10.30.64.199:2019 |
| ai5 | FPR25520086 | Leaf1 eth1/6 | 10.30.64.199:2020 | 10.30.64.199:2021 |
| ai6 | FPR2552000E | Leaf1 eth1/7 | 10.30.64.199:2022 | 10.30.64.199:2023 |
| ai7 | FPR25520021 | Leaf1 eth1/8 | 10.30.64.199:2024 | 10.30.64.199:2025 |

## Related Setups

- [Waco6](./waco6.md) - Paired on same Leaf1
- [Waco7](./waco7.md) - Connected via Leaf2
- [Waco8](./waco8.md) - Connected via Leaf2
- [Waco5-8 Cluster Overview](./waco5-8-overview.md) - Full topology

---
**Setup Name:** Waco5
**Management IP:** 10.30.64.25
**BMC IP:** 10.30.64.15
**Last Updated:** 2026-03-16
**Status:** Active
