# Waco5-8 Cluster - Arista Leaf-Spine Topology

Waco5, Waco6, Waco7, and Waco8 form a 4-node cluster connected via Arista leaf-spine network topology.

## Network Topology

```
                    [Arista Spine]
                   10.30.64.202
                   admin/Gr33nTr33s
                   telnet 10.30.64.120 2011
                          |
        +-----------------+-----------------+
        |                                   |
   [Arista Leaf1]                    [Arista Leaf2]
   10.30.64.201                      10.30.64.203
   telnet 10.30.64.120 2014          telnet 10.30.64.120 2013
        |                                   |
   +----+----+                         +----+----+
   |         |                         |         |
[Waco5]  [Waco6]                   [Waco7]  [Waco8]
```

### Leaf-Spine Port Mapping

**Leaf1 (10.30.64.201) - Connected to Waco5-6:**
- Ports eth1/1-eth8/1: Waco5 ai0-ai7
- Ports eth9/1-eth16/1: Waco6 ai0-ai7
- Ports 33-40: Uplink to Spine ports 1-8

**Leaf2 (10.30.64.203) - Connected to Waco7-8:**
- Ports eth1/1-eth8/1: Waco7 ai0-ai7
- Ports eth9/1-eth16/1: Waco8 ai0-ai7
- Ports 33-40: Uplink to Spine ports 33-40

## Cluster Overview

| Setup | Management IP | BMC IP | Leaf Switch | Switch Ports | Status |
|-------|--------------|--------|-------------|--------------|--------|
| Waco5 | 10.30.64.25 | 10.30.64.15 | Leaf1 (10.30.64.201) | eth1/1-eth8/1 | Active |
| Waco6 | 10.30.64.26 | 10.30.64.16 | Leaf1 (10.30.64.201) | eth9/1-eth16/1 | Active |
| Waco7 | 10.30.64.27 | 10.30.64.17 | Leaf2 (10.30.64.203) | eth1/1-eth8/1 | Active |
| Waco8 | 10.30.64.28 | 10.30.64.18 | Leaf2 (10.30.64.203) | eth9/1-eth16/1 | Active |

**Common Credentials:**
- Host: ubuntu/amd123
- BMC (Waco5): root/Pen1nfra$
- BMC (Others): admin/PenInfra$
- Arista switches: admin/Gr33nTr33s

**Shared NFS Mount:**
- Path: `/mnt/clusterfs` (available on all Waco hosts)

## Console Server Access

All Vulcano and SuC consoles are accessible via:
- Console Server 1: 10.30.64.199 (ports 2002-2033 for Waco5-6)
- Console Server 2: 10.30.64.120 (ports 2010-2041 for Waco7-8)
- Additional: 10.30.64.101 (various ports)

## Quick Access Commands

### SSH to Hosts
```bash
# Waco5
ssh ubuntu@10.30.64.25

# Waco6
ssh ubuntu@10.30.64.26

# Waco7
ssh ubuntu@10.30.64.27

# Waco8
ssh ubuntu@10.30.64.28
```

### Access Arista Switches
```bash
# Spine
telnet 10.30.64.120 2011
# Or: ssh admin@10.30.64.202

# Leaf1 (Waco5-6)
telnet 10.30.64.120 2014
# Or: ssh admin@10.30.64.201

# Leaf2 (Waco7-8)
telnet 10.30.64.120 2013
# Or: ssh admin@10.30.64.203
```

## Multi-Node Testing

This cluster is ideal for:
- **Leaf-spine network topology testing**
- **Multi-hop RDMA testing**
- **Congestion control validation**
- **Load balancing and ECMP testing**
- **Large-scale performance benchmarks**

### Example: Cross-Cluster RDMA Test
```bash
# Test between Waco5 and Waco7 (cross-leaf)
# On Waco5:
ib_write_bw -d ai0 --report_gbits

# On Waco7:
ib_write_bw -d ai0 <waco5_ip> --report_gbits
```

## Setup-Specific Documentation

- [Waco5](./waco5.md) - Detailed configuration and console access
- [Waco6](./waco6.md) - Detailed configuration and console access
- [Waco7](./waco7.md) - Detailed configuration and console access
- [Waco8](./waco8.md) - Detailed configuration and console access

## Known Issues

### Firmware Version Differences
- Waco5/Waco6 typically run newer firmware (e.g., 1.125.1-pi-8)
- May have fixes not present in SMC1/SMC2 (1.125.0-a-133)
- See [Modify QP Path CC Issue](../../MODIFY-QP-PATH-CC-ISSUE.md) for details

---
Last updated: 2026-03-16
