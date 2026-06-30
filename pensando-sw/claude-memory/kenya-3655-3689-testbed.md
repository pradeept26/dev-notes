---
name: Kenya-3655-3689 Testbed
description: Back-to-back Vulcano 1x800G testbed used for AI-6875 SACK retransmit regression debugging
type: reference
originSessionId: 52a4c8d7-ece8-461f-bd47-1415de128069
---
# Kenya-3655-3689 Testbed (Submitter's Setup)

**Topology:** 2-node, back-to-back, Vulcano 1x800G

| Host | Role | Mgmt IP | BMC IP | BMC creds |
|------|------|---------|--------|-----------|
| kenya-3655 | server | 10.30.55.43 | 10.30.55.22 | admin/Pen1nfra$ |
| kenya-3689 | client | 10.30.55.44 | 10.30.55.23 | admin/Pen1nfra$ |

**SSH:** `root/docker`
**Console server:** 10.30.55.254
- kenya-3655 DSC: `telnet 10.30.55.254 12` / SuC: `telnet 10.30.55.254 13`
- kenya-3689 DSC: `telnet 10.30.55.254 14` / SuC: `telnet 10.30.55.254 15`

**RDMA device:** `ionic_0`
**Data interface:** `enp195s0f3`, MTU 9000
**IPv6:** fd00::1 (kenya-3655) / fd00::2 (kenya-3689)

**Testbed YAML:** `~/systest-agentq/projects/ainic/meta-roce/testbeds/kenya-3655-3689.yaml`

## Bringup (required after every firmware flash or card reset — NO script, manual only)

```bash
for HOST in 10.30.55.43 10.30.55.44; do
  ssh root@$HOST "
    echo 2048 > /proc/sys/vm/nr_hugepages
    for p in 0 1 2 3 4 5 6 7; do nicctl update pipeline rdma path -p \$p --count 8; done
    nicctl update qos --classification-type dscp
    nicctl update qos dscp-to-purpose --dscp 46 --purpose rdma-ack
    nicctl update qos dscp-to-priority --dscp 46 --priority 2
    nicctl update qos dscp-to-priority --dscp 24 --priority 3"
done
ssh root@10.30.55.43 "ip -6 addr add fd00::1/64 dev enp195s0f3 2>/dev/null || true; ip link set enp195s0f3 mtu 9000"
ssh root@10.30.55.44 "ip -6 addr add fd00::2/64 dev enp195s0f3 2>/dev/null || true; ip link set enp195s0f3 mtu 9000"
```

## IB Write BW Test (standard for AI-6875 regression)

```bash
# Server (kenya-3655):
ib_write_bw -d ionic_0 -x 1 --qp=8 -s 1048576 -n 12500 --report_gbits --ipv6-addr -p 5101

# Client (kenya-3689):
ib_write_bw -d ionic_0 -x 1 --qp=8 -s 1048576 -n 12500 --report_gbits --ipv6-addr -p 5101 fd00::1
```

**Expected baseline:** ~773 Gb/s (RCN disabled, 1x800G)

## Drop Injection (AI-6875 regression test)

```bash
# On server (kenya-3655) — before starting ib_write_bw:
nicctl debug update pipeline internal rdma-drop \
  --enable --drop-type rand --frequency 2000 --packet-types 0x18

# Disable after test:
nicctl debug update pipeline internal rdma-drop --disable
```

**Expected with drops:**
- Broken (AI-6746 present): ~564 Gb/s (27% collapse, SACK fires 7x)
- Fixed (AI-6746 reverted or Igor's fix): ~772 Gb/s (0.1% degradation, healthy)
