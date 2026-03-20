# Waco Cluster Network Topology
**Updated**: 2026-03-20
**Architecture**: 2-Spine / 2-Leaf Arista Topology

---

## Switch Overview

### Console Access (All via 10.30.64.120)

| Switch | Console | Credentials |
|--------|---------|-------------|
| **LEAF1** | telnet 10.30.64.120 2025 | admin / Gr33nTr33s |
| **LEAF2** | telnet 10.30.64.120 2013 | admin / Gr33nTr33s |
| **SPINE1** | telnet 10.30.64.120 2011 | admin / Gr33nTr33s |
| **SPINE2** | telnet 10.30.64.120 2014 | admin / Gr33nTr33s |

---

## LEAF1 Connections

**Hosts**: Waco1, 2, 3, 4 (32 NICs total)

### Waco1 → LEAF1

| Slot | NIC | Leaf Port | Notes |
|------|-----|-----------|-------|
| 1 | ai0 | 5 | |
| 2 | ai1 | 6 | |
| 3 | ai2 | 7 | |
| 4 | ai3 | 8 | |
| 5 | ai4 | 4 | |
| 6 | ai5 | 3 | |
| 7 | ai6 | 1 | |
| 8 | ai7 | 2 | |

### Waco2 → LEAF1

| Slot | NIC | Leaf Port | Notes |
|------|-----|-----------|-------|
| 1 | ai0 | 13 | |
| 2 | ai1 | 14 | |
| 3 | ai2 | 15 | |
| 4 | ai3 | 16 | |
| 5 | ai4 | 12 | |
| 6 | ai5 | 11 | |
| 7 | ai6 | 9 | |
| 8 | ai7 | 10 | |

### Waco3 → LEAF1

| Slot | NIC | Leaf Port | Notes |
|------|-----|-----------|-------|
| 1 | ai0 | 21 | |
| 2 | ai1 | 22 | |
| 3 | ai2 | 23 | |
| 4 | ai3 | 24 | |
| 5 | ai4 | 20 | |
| 6 | ai5 | 19 | |
| 7 | ai6 | 17 | |
| 8 | ai7 | 18 | |

### Waco4 → LEAF1

| Slot | NIC | Leaf Port | Notes |
|------|-----|-----------|-------|
| 1 | ai0 | 29 | |
| 2 | ai1 | 30 | |
| 3 | ai2 | 31 | |
| 4 | ai3 | 32 | |
| 5 | ai4 | 28 | |
| 6 | ai5 | 27 | |
| 7 | ai6 | 25 | |
| 8 | ai7 | 26 | |

**LEAF1 Uplinks to Spine**:
- Ports 49-56 → SPINE1 ports 49-56
- Ports 57-64 → SPINE2 ports 49-56

---

## LEAF2 Connections

**Hosts**: Waco5, 6, 7, 8 (32 NICs total)

### Waco5 → LEAF2

| Slot | NIC | Leaf Port | Notes |
|------|-----|-----------|-------|
| 1 | ai0 | 5 | |
| 2 | ai1 | 6 | |
| 3 | ai2 | 7 | |
| 4 | ai3 | 8 | |
| 5 | ai4 | 4 | |
| 6 | ai5 | 3 | |
| 7 | ai6 | 1 | |
| 8 | ai7 | 2 | |

### Waco6 → LEAF2

| Slot | NIC | Leaf Port | Notes |
|------|-----|-----------|-------|
| 1 | ai0 | 13 | |
| 2 | ai1 | 14 | |
| 3 | ai2 | 15 | |
| 4 | ai3 | 16 | |
| 5 | ai4 | 12 | |
| 6 | ai5 | 11 | |
| 7 | ai6 | 9 | |
| 8 | ai7 | 10 | |

### Waco7 → LEAF2

| Slot | NIC | Leaf Port | Notes |
|------|-----|-----------|-------|
| 1 | ai0 | 21 | |
| 2 | ai1 | 22 | |
| 3 | ai2 | 23 | |
| 4 | ai3 | 24 | |
| 5 | ai4 | 20 | |
| 6 | ai5 | 19 | |
| 7 | ai6 | 17 | |
| 8 | ai7 | 18 | |

### Waco8 → LEAF2

| Slot | NIC | Leaf Port | Notes |
|------|-----|-----------|-------|
| 1 | ai0 | 29 | |
| 2 | ai1 | 30 | |
| 3 | ai2 | 31 | |
| 4 | ai3 | 32 | |
| 5 | ai4 | 28 | |
| 6 | ai5 | 27 | |
| 7 | ai6 | 25 | |
| 8 | ai7 | 26 | |

**LEAF2 Uplinks to Spine**:
- Ports 49-56 → SPINE1 ports 57-64
- Ports 57-64 → SPINE2 ports 57-64

---

## Port Mapping Pattern

**Slot to Leaf Port Mapping** (consistent across all Wacos):

| Slot | Waco1/5 | Waco2/6 | Waco3/7 | Waco4/8 |
|------|---------|---------|---------|---------|
| 1 (ai0) | 5 | 13 | 21 | 29 |
| 2 (ai1) | 6 | 14 | 22 | 30 |
| 3 (ai2) | 7 | 15 | 23 | 31 |
| 4 (ai3) | 8 | 16 | 24 | 32 |
| 5 (ai4) | 4 | 12 | 20 | 28 |
| 6 (ai5) | 3 | 11 | 19 | 27 |
| 7 (ai6) | 1 | 9 | 17 | 25 |
| 8 (ai7) | 2 | 10 | 18 | 26 |

**Note**: Slot numbering is **non-sequential** on switch ports
- Slots 1-4 → Ports 5-8, 13-16, 21-24, 29-32
- Slots 5-8 → Ports 4,3,1,2, 12,11,9,10, 20,19,17,18, 28,27,25,26

---

## Network Architecture

```
                    ┌─────────────────┐
                    │   SPINE1        │
                    │  (120:2011)     │
                    └────────┬────────┘
                    49-56 ↓  ↓ 57-64
                 ┌─────────────────────┐
          ┌──────┤                     ├──────┐
          ↓      │                     │      ↓
    ┌─────────┐  │   ┌─────────────┐  │  ┌─────────┐
    │  LEAF1  │  │   │   SPINE2    │  │  │  LEAF2  │
    │(120:2025)│  │   │  (120:2014) │  │  │(120:2013)│
    └────┬────┘  │   └──────┬──────┘  │  └────┬────┘
         │       │          │         │       │
   Waco1-4    49-56 ←──────┴────→ 57-64   Waco5-8
   (32 NICs)      57-64 ←──────────────→
```

**Topology Type**: Full Mesh 2-Spine / 2-Leaf
- **Redundancy**: Each leaf connects to BOTH spines
- **Load Balancing**: ECMP across spine uplinks
- **Total Capacity**: 64 NICs × 400G = 25.6 Tbps host bandwidth

---

## Spine Interconnect Details

### LEAF1 Uplinks
- **To SPINE1**: Ports 49-56 → SPINE1 ports 49-56
- **To SPINE2**: Ports 57-64 → SPINE2 ports 49-56

### LEAF2 Uplinks
- **To SPINE1**: Ports 49-56 → SPINE1 ports 57-64
- **To SPINE2**: Ports 57-64 → SPINE2 ports 57-64

**Uplink Speed**: 800G per uplink group (8 ports × 100G)

---

## Network Subnets

**Data Network**: 30.0.0.0/8 (RoCE/RDMA traffic)
**Management Network**: 10.30.64.0/22 (SSH, BMC, console servers)

### Per-Server Allocation

| Server | Data Network | Management IP | BMC IP |
|--------|--------------|---------------|--------|
| Waco1 | 30.1.0.0/24 | 10.30.64.21 | 10.30.64.11 |
| Waco2 | 30.2.0.0/24 | 10.30.64.22 | 10.30.64.12 |
| Waco3 | 30.3.0.0/24 | 10.30.64.23 | 10.30.64.13 |
| Waco4 | 30.4.0.0/24 | 10.30.64.24 | 10.30.64.14 |
| Waco5 | 30.5.0.0/24 | 10.30.64.25 | 10.30.64.15 |
| Waco6 | 30.6.0.0/24 | 10.30.64.26 | 10.30.64.16 |
| Waco7 | 30.7.0.0/24 | 10.30.64.27 | 10.30.64.17 |
| Waco8 | 30.8.0.0/24 | 10.30.64.28 | 10.30.64.18 |

---

## Access Credentials Summary

### Switches
- **All switches** (LEAF1, LEAF2, SPINE1, SPINE2): admin / Gr33nTr33s

### Console Servers
- **10.30.64.101**: Pen1nfra$ (primary) or N0isystem$ (alternate)
- **10.30.64.120**: Pen1nfra$ or N0isystem$
- **10.30.64.199**: N0isystem$ (primary for this server)

### Servers
- **All Waco hosts**: ubuntu / amd123
- **All BMCs**: admin / PenInfra$ or root / Pen1nfra$

---

## Common Switch Commands (Arista EOS)

### Show Commands
```bash
# Interface status
show interfaces status

# Port counters
show interfaces counters

# BGP status
show ip bgp summary

# LLDP neighbors
show lldp neighbors

# Running config
show running-config

# Specific interface
show interfaces Ethernet1/1

# Transceivers
show interfaces transceiver
```

### Configuration
```bash
# Enter config mode
configure

# Interface configuration
interface Ethernet1/1
  description Waco1-ai0
  speed 400g
  no shutdown
```

---

## Traffic Flow Example

**East-West**: Waco1 ai0 (LEAF1) ↔ Waco5 ai0 (LEAF2)

```
Waco1 ai0 (slot1, LEAF1 port 5)
    ↓
LEAF1 port 5
    ↓
LEAF1 uplink (port 49-56 or 57-64)
    ↓
SPINE1 or SPINE2 (ECMP)
    ↓
LEAF2 uplink
    ↓
LEAF2 port 5
    ↓
Waco5 ai0 (slot1, LEAF2 port 5)
```

**Hops**: 3 (Leaf → Spine → Leaf)
**Redundancy**: 2 spine paths available

---

## Network Statistics

**Total Host Ports**: 64 (8 servers × 8 NICs)
**Total Leaf Ports**: 2 × 32 = 64 ports used for hosts
**Total Spine Uplinks**: 32 ports (4 uplink groups × 8 ports)
**Aggregate Bandwidth**: 25.6 Tbps (host) + spine oversubscription

**Link Speeds**:
- Host NICs: 400G per NIC
- Leaf-Spine Uplinks: 800G per uplink group (8×100G)

---

## Notes

- **Slot-to-port mapping is non-sequential** (see mapping table)
- Slot 7 (ai6) → Port 1, Slot 8 (ai7) → Port 2
- Slot 6 (ai5) → Port 3, Slot 5 (ai4) → Port 4
- Then Slot 1-4 (ai0-3) → Port 5-8
- Pattern repeats for each Waco (+8 port offset)

- **All switches accessible via same console server** (10.30.64.120)
- **Full spine redundancy**: Each leaf has dual uplinks to both spines
- **ECMP load balancing** across spine paths

---

**Last Updated**: March 20, 2026
**Source**: User-provided topology mapping
**Console Server**: 10.30.64.120 (all switches)
**Credentials**: admin / Gr33nTr33s (all switches)
