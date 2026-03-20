# Waco Cluster Network Topology
**Updated**: 2026-03-18

## Overview

3 Arista Leaf Switches connecting Waco1-8 servers in Leaf-Spine topology.
All NICs connected at 400G, uplinks at 800G.

---

## Leaf Switch 1 (10.30.64.200)

**Connected Hosts**: waco1-4
**Loopback0**: 192.168.0.3
**Total Ports**: 32/32 connected ✅

### Waco1 Connections (8 NICs)

| Port | NIC | Switch IP | Speed | Status |
|------|-----|-----------|-------|--------|
| Et1/1 | ai0 | 30.1.0.0/31 | 400G | connected |
| Et2/1 | ai1 | 30.1.1.0/31 | 400G | connected |
| Et3/1 | ai2 | 30.1.2.0/31 | 400G | connected |
| Et4/1 | ai3 | 30.1.3.0/31 | 400G | connected |
| Et5/1 | ai4 | 30.1.4.0/31 | 400G | connected |
| Et6/1 | ai5 | 30.1.5.0/31 | 400G | connected |
| Et7/1 | ai6 | 30.1.6.0/31 | 400G | connected |
| Et8/1 | ai7 | 30.1.7.0/31 | 400G | connected |

### Waco2 Connections (8 NICs)

| Port | NIC | Switch IP | Speed | Status |
|------|-----|-----------|-------|--------|
| Et9/1 | ai0 | 30.2.0.0/31 | 400G | connected |
| Et10/1 | ai1 | 30.2.1.0/31 | 400G | connected |
| Et11/1 | ai2 | 30.2.2.0/31 | 400G | connected |
| Et12/1 | ai3 | 30.2.3.0/31 | 400G | connected |
| Et13/1 | ai4 | 30.2.4.0/31 | 400G | connected |
| Et14/1 | ai5 | 30.2.5.0/31 | 400G | connected |
| Et15/1 | ai6 | 30.2.6.0/31 | 400G | connected |
| Et16/1 | ai7 | 30.2.7.0/31 | 400G | connected |

### Waco3 Connections (8 NICs)

| Port | NIC | Switch IP | Speed | Status |
|------|-----|-----------|-------|--------|
| Et17/1 | ai0 | 30.3.0.0/31 | 400G | connected |
| Et18/1 | ai1 | 30.3.1.0/31 | 400G | connected |
| Et19/1 | ai2 | 30.3.2.0/31 | 400G | connected |
| Et20/1 | ai3 | 30.3.3.0/31 | 400G | connected |
| Et21/1 | ai4 | 30.3.4.0/31 | 400G | connected |
| Et22/1 | ai5 | 30.3.5.0/31 | 400G | connected |
| Et23/1 | ai6 | 30.3.6.0/31 | 400G | connected |
| Et24/1 | ai7 | 30.3.7.0/31 | 400G | connected |

### Waco4 Connections (8 NICs)

| Port | NIC | Switch IP | Speed | Status |
|------|-----|-----------|-------|--------|
| Et25/1 | ai0 | 30.4.0.0/31 | 400G | connected |
| Et26/1 | ai1 | 30.4.1.0/31 | 400G | connected |
| Et27/1 | ai2 | 30.4.2.0/31 | 400G | connected |
| Et28/1 | ai3 | 30.4.3.0/31 | 400G | connected |
| Et29/1 | ai4 | 30.4.4.0/31 | 400G | connected |
| Et30/1 | ai5 | 30.4.5.0/31 | 400G | connected |
| Et31/1 | ai6 | 30.4.6.0/31 | 400G | connected |
| Et32/1 | ai7 | 30.4.7.0/31 | 400G | connected |

**Uplinks**: Et33-40/1 (800G, TO_SPINE QoS)

---

## Leaf Switch 2 (10.30.64.201)

**Connected Hosts**: waco5-6
**Loopback0**: 192.168.0.1
**Total Ports**: 16/16 connected ✅

### Waco5 Connections (8 NICs)

| Port | NIC | Switch IP | Speed | Status |
|------|-----|-----------|-------|--------|
| Et1/1 | ai0 | 30.5.0.0/31 | 400G | connected |
| Et2/1 | ai1 | 30.5.1.0/31 | 400G | connected |
| Et3/1 | ai2 | 30.5.2.0/31 | 400G | connected |
| Et4/1 | ai3 | 30.5.3.0/31 | 400G | connected |
| Et5/1 | ai4 | 30.5.4.0/31 | 400G | connected |
| Et6/1 | ai5 | 30.5.5.0/31 | 400G | connected |
| Et7/1 | ai6 | 30.5.6.0/31 | 400G | connected |
| Et8/1 | ai7 | 30.5.7.0/31 | 400G | connected |

### Waco6 Connections (8 NICs)

| Port | NIC | Switch IP | Speed | Status |
|------|-----|-----------|-------|--------|
| Et9/1 | ai0 | 30.6.0.0/31 | 400G | connected |
| Et10/1 | ai1 | 30.6.1.0/31 | 400G | connected |
| Et11/1 | ai2 | 30.6.2.0/31 | 400G | connected |
| Et12/1 | ai3 | 30.6.3.0/31 | 400G | connected |
| Et13/1 | ai4 | 30.6.4.0/31 | 400G | connected |
| Et14/1 | ai5 | 30.6.5.0/31 | 400G | connected |
| Et15/1 | ai6 | 30.6.6.0/31 | 400G | connected |
| Et16/1 | ai7 | 30.6.7.0/31 | 400G | connected |

**Uplinks**: Et33-40/1 (800G, TO_SPINE QoS)

---

## Leaf Switch 3 (10.30.64.203)

**Connected Hosts**: waco7-8
**Loopback0**: 192.168.0.2
**Total Ports**: 8/16 connected ⚠️

### Waco7 Connections (8 NICs) - ❌ ALL DOWN

| Port | NIC | Switch IP | Speed | Status |
|------|-----|-----------|-------|--------|
| Et1/1 | ai0 | 30.7.0.0/31 | 400G | **notconnect** |
| Et2/1 | ai1 | 30.7.1.0/31 | 400G | **notconnect** |
| Et3/1 | ai2 | 30.7.2.0/31 | 400G | **notconnect** |
| Et4/1 | ai3 | 30.7.3.0/31 | 400G | **notconnect** |
| Et5/1 | ai4 | 30.7.4.0/31 | 400G | **notconnect** |
| Et6/1 | ai5 | 30.7.5.0/31 | 400G | **notconnect** |
| Et7/1 | ai6 | 30.7.6.0/31 | 400G | **notconnect** |
| Et8/1 | ai7 | 30.7.7.0/31 | 400G | **notconnect** |

**Issue**: Only 4/8 NICs detected on host, all switch ports down

### Waco8 Connections (8 NICs)

| Port | NIC | Switch IP | Speed | Status |
|------|-----|-----------|-------|--------|
| Et9/1 | ai0 | 30.8.0.0/31 | 400G | connected |
| Et10/1 | ai1 | 30.8.1.0/31 | 400G | connected |
| Et11/1 | ai2 | 30.8.2.0/31 | 400G | connected |
| Et12/1 | ai3 | 30.8.3.0/31 | 400G | connected |
| Et13/1 | ai4 | 30.8.4.0/31 | 400G | connected |
| Et14/1 | ai5 | 30.8.5.0/31 | 400G | connected |
| Et15/1 | ai6 | 30.8.6.0/31 | 400G | connected |
| Et16/1 | ai7 | 30.8.7.0/31 | 400G | connected |

**Uplinks**: Et33-40/1 (800G, TO_SPINE QoS)

---

## Network Summary

### Switch IP Ranges

| Host | NIC Subnet | Range |
|------|------------|-------|
| Waco1 | 30.1.0.0/24 | 30.1.0.0 - 30.1.7.1 |
| Waco2 | 30.2.0.0/24 | 30.2.0.0 - 30.2.7.1 |
| Waco3 | 30.3.0.0/24 | 30.3.0.0 - 30.3.7.1 |
| Waco4 | 30.4.0.0/24 | 30.4.0.0 - 30.4.7.1 |
| Waco5 | 30.5.0.0/24 | 30.5.0.0 - 30.5.7.1 |
| Waco6 | 30.6.0.0/24 | 30.6.0.0 - 30.6.7.1 |
| Waco7 | 30.7.0.0/24 | 30.7.0.0 - 30.7.7.1 |
| Waco8 | 30.8.0.0/24 | 30.8.0.0 - 30.8.7.1 |

### Connectivity Status

**Fully Connected** (all 8 NICs):
- ✅ Waco1 (8/8 ports up)
- ✅ Waco2 (8/8 ports up)
- ✅ Waco3 (8/8 ports up)
- ✅ Waco4 (8/8 ports up)
- ✅ Waco5 (8/8 ports up)
- ✅ Waco6 (8/8 ports up)
- ✅ Waco8 (8/8 ports up)

**Issues**:
- ❌ Waco7: 0/8 switch ports connected (all "notconnect")
  - Host has 4/8 NICs detected
  - Network links not established

**Total**: 56/64 switch ports connected (87.5%)

---

## Topology Notes

- **3 Leaf Switches** in Leaf-Spine topology
- **Each NIC** gets dedicated /31 subnet (point-to-point)
- **400G links** per NIC
- **800G uplinks** to spine switches
- **QoS configured** on uplinks (TO_SPINE)

### Leaf to Host Mapping:
- **Leaf 1 (10.30.64.200)**: Waco1, 2, 3, 4
- **Leaf 2 (10.30.64.201)**: Waco5, 6
- **Leaf 3 (10.30.64.203)**: Waco7, 8

---

## For RDMA/RoCE Testing

Each NIC has a switch-side IP on the 30.X.Y.Z network.
These are the IPs used for RoCE traffic between nodes.

Example: Waco3 ai0 ↔ Waco4 ai0
- Waco3 ai0: 30.3.0.1 (host side)
- Switch: 30.3.0.0 / 30.4.0.0
- Waco4 ai0: 30.4.0.1 (host side)

Traffic routes through leaf switches and spine.

---

**Source**: Switch port status as of 2026-03-18
**Location**: Arista Leaf-Spine network
**Access**: Leaf switches at 10.30.64.200, 201, 203

---

## Spine Switches

### Spine Switch (10.30.64.202)
**Credentials**: admin / Gr33nTr33s  
**Role**: Aggregates traffic from all 3 leaf switches

**Uplink Connections**:
- Leaf 1 (10.30.64.200): Et33-40/1 → Spine uplinks (800G)
- Leaf 2 (10.30.64.201): Et33-40/1 → Spine uplinks (800G)
- Leaf 3 (10.30.64.203): Et33-40/1 → Spine uplinks (800G)

**Total Uplink Capacity**: 3 x 800G = 2.4 Tbps

**QoS**: TO_SPINE marking on all leaf uplinks

---

## Network Summary

**Topology**: 3-tier Leaf-Spine
- **Leaf tier**: 3 Arista switches (10.30.64.200/201/203)
- **Spine tier**: 1+ Arista switches (10.30.64.202 confirmed)
- **Access**: 64 host NICs at 400G each
- **Uplinks**: 800G leaf-to-spine links
- **Data network**: 30.0.0.0/8 (RoCE/RDMA)
- **Management**: 10.30.64.0/22

**Access Details**:
- **Leaf switches**: admin credentials
- **Spine switch**: admin / Gr33nTr33s
- **Console servers**: 
  - 10.30.64.101: Pen1nfra$ or N0isystem$
  - 10.30.64.120: Pen1nfra$ or N0isystem$
  - 10.30.64.199: N0isystem$

