---
name: kenya-perf-3/4 baseline and setup
description: Performance baseline numbers and setup details for kenya-perf-3 and kenya-perf-4 Vulcano testbed (back-to-back 800G copper)
type: project
originSessionId: 3b323503-29c9-455d-a2a6-573536c78e79
---
## Testbed: kenya-perf-3 / kenya-perf-4 (back-to-back, 800G copper)

### Setup Details
| | kenya-perf-3 (Server) | kenya-perf-4 (Client) |
|---|---|---|
| Mgmt IP | 10.30.52.66 | 10.30.52.75 |
| BMC IP | 10.30.52.61 | 10.30.52.74 |
| RDMA IP | 10.1.1.1/24 on enp195s0f2 | 10.1.1.2/24 on enp195s0f2 |
| RDMA Device | rocep195s0f2 | rocep195s0f2 |
| NIC BDF | 0000:c1:00.0 | 0000:c1:00.0 |
| NIC UUID | 42424650-4632-3630-3430-303134000000 | 42424650-4632-3630-3430-303031000000 |
| Serial | FPF26040014 | FPF26040001 |
| MAC | 04:90:81:a7:71:20 | 04:90:81:a7:6f:58 |
| Credentials | root / docker | root / docker |
| Port | 800G, RS FEC, MTU 9216, Copper OSFP-800G-CR8 | same |

### Post-reboot Setup Commands
```bash
# On kenya-perf-3 (10.30.52.66):
ip addr add 10.1.1.1/24 dev enp195s0f2
ip link set enp195s0f2 mtu 9000 up

# On kenya-perf-4 (10.30.52.75):
ip addr add 10.1.1.2/24 dev enp195s0f2
ip link set enp195s0f2 mtu 9000 up

# On both — configure 8 paths and enable RCN:
nicctl update pipeline rdma path -p 0 --path-count 8
nicctl update pipeline rdma congestion-control profile -p 0 --rcn enabled
```

### Baseline (2026-05-09) — FW 1.125.0-a-228, RCN DISABLED

| QPs | Uni (Gbps) | Bi (Gbps) |
|-----|-----------|-----------|
| 8 | 777.56 | 1523.64 |
| 16 | 777.57 | 1520.73 |
| 32 | 777.59 | 1519.33 |

### RCN ON Results (2026-05-09) — FW 1.125.0-a-228, RCN ENABLED, 8 paths

| QPs | Uni (Gbps) | Bi (Gbps) | Uni Delta | Bi Delta |
|-----|-----------|-----------|-----------|----------|
| 8 | 757.39 | 1348.03 | -2.6% | -11.5% |
| 16 | 741.83 | 1334.30 | -4.6% | -12.3% |
| 32 | 757.58 | 1294.83 | -2.6% | -14.8% |

Deep-dive (16 QPs, 8M, 30s, bi): 1338.71 Gbps — confirms degradation.

### Retry / CC Statistics (cumulative across all tests, RCN ON)

| Metric | kenya-perf-3 | kenya-perf-4 |
|--------|-------------|-------------|
| CC additive increments | 19,800,876 | 21,258,344 |
| CC multiplicative decrements | 19,800,094 | 21,258,292 |
| Path disabled (window exhausted) | 140,780,834 | 140,872,497 |
| Path bootstraps | 140 | 141 |
| Packet drops | 0 | 0 |

### Analysis
- Bidirectional shows 11-15% degradation with RCN ON (worsens with more QPs)
- Root cause: aggressive CWND clamping — ~141M path-disabled events vs ~20M CC events
- CWND values collapsed to 2-34 at snapshot time; paths stuck at minimum window
- Zero drops — degradation is purely CC throttling, not link/datapath issue
- 91 paths in error on server, 83 on client (cwnd_retry stuck, scheduler not dispatching retx)

### Asicmon Deep-Dive: Bidirectional RCN Regression Root Cause (2026-05-09)
- **Pipeline:** NOT bottlenecked (DRDY=100%, 0% stage XOFF)
- **PCIe:** NOT bottlenecked (Gen6 x16, 1346G total, 76% per-dir)
- **Root cause:** CC algorithmic — symmetric RCN feedback loop in bidir
  - ~19M CC multiplicative decrements per node (1:1 with increments = pure oscillation)
  - 113-140M path-disabled events per node (17-22% of TX attempts)
  - 145K-180K path-disables/sec/QP → 1-2 of 8 paths disabled at any time
  - PF_PBI_XOFF0=100% (ingress buffer saturated), PBE_NODRDY=108-130M (egress contention)
- **S4 drops:** 4.5-5.6M/s per UD pipe (PWND=0, path window full)

### Definitive Baseline Stats (2026-05-09) — 16 QP bidir, 60s, RCN ON, FW 1.125.0-a-228

**Bandwidth: 1335.74 Gbps** bidirectional

| Metric | Server (per active path avg) | Client (per active path avg) |
|--------|------------------------------|------------------------------|
| CC additive increments | 290,056 | 374,495 |
| CC multiplicative decrements | 290,054 | 374,494 |
| cwnd_retry events | 2,940,411 | 3,170,210 |
| RTO retransmits | 0 | 0 |
| SACK retransmits | 0 | 0 |
| Path disabled (window exhausted) | 0 | 0 |
| Path inactive (congestion) | 0 | 0 |
| Drops / OOO / ECN / CNP | 0 | 0 |
| Active paths avg | 4.3 / 8 | 4.3 / 8 |
| Inactive paths total | 119 / 256 | 117 / 256 |
| RTT | 3-12μs QP, 99.9% < 25μs | 4-12μs QP, 99.9% < 25μs |

**Key comparison metrics for post-patch:**
1. Bandwidth (target: closer to 1521 Gbps RCN-off baseline)
2. Active paths avg (target: higher than 4.3/8)
3. cwnd_retry events per path (target: lower than ~3M/60s)
4. S4 pipeline drops (target: lower than 15-17M/s)

### Post-Patch Results (2026-05-09) — FW 1.125.0-a-229-1-gd21230f0511-dirty

| QPs | Dir | RCN-ON Baseline | New FW | Delta |
|-----|-----|----------------|--------|-------|
| 8 | Uni | 757.39 | 232.35 | **-69.3%** |
| 8 | Bi | 1348.03 | 970.21 | **-28.0%** |
| 16 | Uni | 741.83 | 449.26 | **-39.4%** |
| 16 | Bi | 1334.30 | 1331.46 | -0.2% |
| 32 | Uni | 757.58 | 714.43 | -5.7% |
| 32 | Bi | 1294.83 | 1242.75 | -4.0% |

60s definitive (16 QP bidir): 1362.94 Gbps (+2.1%)

CC churn: cwnd_retry -79%, CC events -73%. Zero RTO/drops.
**Issue:** Severe unidirectional regression at low QPs (8 QP uni: -69%). RX hysteresis too conservative for uni flows where ACKs don't keep paths warm.

**Why:** Baseline before applying commit 0ece30837e (unify path re-activation under RX hysteresis).
**How to apply:** Uni regression needs fix before shipping. Bidir improved as expected.
