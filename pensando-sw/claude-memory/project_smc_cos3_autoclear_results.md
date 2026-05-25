---
name: SMC1/SMC2 cos3-autoclear test results
description: IB and RCCL results with cos3 autoclear ON vs OFF on SMC1/SMC2. Includes QP-level path disabled, asicmon pipeline stats, and live QP state during traffic.
type: project
originSessionId: 3b323503-29c9-455d-a2a6-573536c78e79
---
## Testbed: SMC1/SMC2 (8 NICs each, 400G, Micas switch)

## Phase A: cos3-autoclear ON (FW 1.125.0-a-229-2-g50b2ee89bb4-dirty)

### IB Results (roce_benic1p1, 16 QP, 8M msg, 120s bidir)
- **Bandwidth: 716.72 Gbps**

| QP | TX Pkts | Path disabled (QP stat) | Disabled/TX | Bootstraps |
|---|---|---|---|---|
| 2 | 83.9M | 11,515,426 | **14%** | 8 |
| 3 | 84.0M | 11,703,099 | **14%** | 8 |
| 4 | 81.2M | 31,159,133 | **38%** | 6 |
| 5 | 81.4M | 31,488,901 | **39%** | 6 |
| 6 | 78.8M | 21,495,138 | **27%** | 4 |
| 7 | 82.9M | 27,802,774 | **34%** | 7 |
| 8 | 81.3M | 31,342,733 | **39%** | 6 |
| 9 | 78.7M | 21,350,495 | **27%** | 4 |
| **Avg** | | | **29%** | |

Live during traffic:
- Total disabled paths (snapshot): 24/128 (19%)
- S4 drops: 19.7M/s per UD pipe
- TXS Q3 XOFF: 84-90%, Q2 XOFF: 45-48%
- PCIe: 357G read + 366G write = 723G total
- PF_PBI_XOFF0: 100%

### RCCL Results (alltoall, 16G msg, 200 iter)
- **busBw: 83.05 GB/s**

| QP | TX Pkts | Path disabled (QP stat) | Disabled/TX | Bootstraps |
|---|---|---|---|---|
| 14 | 1.7M | 0 | 0% | 1 |
| 15 | 54.3M | 16,087,792 | 30% | 8 |
| 16 | 54.3M | 19,713,895 | 36% | 6 |
| 17 | 54.3M | 16,260,518 | 30% | 8 |
| 18 | 54.3M | 16,202,195 | 30% | 8 |
| 19 | 54.3M | 13,264,858 | 24% | 4 |
| 20 | 54.3M | 13,235,850 | 24% | 4 |
| 21 | 54.3M | 16,286,865 | 30% | 8 |

---

## Phase B: Baseline (FW 1.125.0-a-229, cos3 autoclear OFF)

### IB Results (roce_benic1p1, 16 QP, 8M msg, 120s bidir)
- **Bandwidth: 748.67 Gbps**

| QP | TX Pkts | Path disabled (QP stat) | Disabled/TX | Bootstraps |
|---|---|---|---|---|
| 2 | 99.9M | 43,048,116 | **43%** | 8 |
| 3 | 82.9M | 36,260,892 | **44%** | 5 |
| 4 | 84.8M | 43,997,345 | **52%** | 6 |
| 5 | 82.9M | 36,290,401 | **44%** | 5 |
| 6 | 81.0M | 28,278,979 | **35%** | 4 |
| 7 | 81.0M | 28,305,407 | **35%** | 4 |
| 8 | 81.0M | 28,273,704 | **35%** | 4 |
| 9 | 78.5M | 20,099,673 | **26%** | 5 |
| **Avg** | | | **39%** | |

Live during traffic:
- Total disabled paths (snapshot): 38/128 (30%)
- S4 drops: 21.1M/s per UD pipe
- TXS Q3 XOFF: 91-97%, Q2 XOFF: 21%
- PCIe: 371G read + 385G write = 756G total
- PF_PBI_XOFF0: 100%

### RCCL Results (alltoall, 16G msg, 200 iter)
- **busBw: 86.62 GB/s**

| QP | TX Pkts | Path disabled (QP stat) | Disabled/TX | Bootstraps |
|---|---|---|---|---|
| 14 | 54.3M | 25,896,869 | 48% | 7 |
| 15 | 54.3M | 25,866,064 | 48% | 7 |
| 16 | 54.3M | 18,226,255 | 34% | 5 |
| 17 | 54.3M | 29,192,494 | 54% | 8 |
| 18 | 54.3M | 18,225,149 | 34% | 5 |
| 19 | 1.7M | 0 | 0% | 1 |
| 20 | 54.3M | 29,188,410 | 54% | 8 |
| 21 | 54.3M | 29,171,431 | 54% | 8 |

---

## Final Comparison

### Bandwidth
| Test | Autoclear ON | Baseline OFF | Delta |
|------|-------------|-------------|-------|
| **IB bidir** | 716.72 Gbps | **748.67 Gbps** | **-4.3%** |
| **RCCL alltoall** | 83.05 GB/s | **86.62 GB/s** | **-4.1%** |

### QP-level Path Disabled (window exhausted) — IB
| Metric | Autoclear ON | Baseline OFF | Delta |
|--------|-------------|-------------|-------|
| Avg disabled/TX ratio | **29%** | **39%** | **-10pp** (ON better) |
| QPs with 8 bootstraps | 2 (QP 2,3) at 14% | 1 (QP 2) at 43% | ON much better |
| S4 drops/s per UD | 19.7M | 21.1M | -7% (ON lower) |
| Disabled paths live snapshot | 24/128 (19%) | 38/128 (30%) | -11pp (ON better) |

### QP-level Path Disabled — RCCL
| Metric | Autoclear ON | Baseline OFF | Delta |
|--------|-------------|-------------|-------|
| Avg disabled/TX ratio (active QPs) | ~29% | ~46% | **-17pp** (ON better) |

### Pipeline (asicmon)
| Metric | Autoclear ON | Baseline OFF |
|--------|-------------|-------------|
| TXS Q3 XOFF | 84-90% | 91-97% |
| TXS Q2 XOFF | **45-48%** | 21% |
| S4 drops/s | 19.7M | 21.1M |
| PCIe total | 723G | 756G |
| PF_PBI_XOFF0 | 100% | 100% |
| PR_DROP | 0 | 0 |

### Conclusions
1. **Baseline is 4% faster** on both IB and RCCL
2. **Autoclear reduces path disabled by 10-17pp** (29% vs 39% IB, 29% vs 46% RCCL)
3. **But more path recovery doesn't help BW** — autoclear adds Q2 (cosA) scheduler contention (45% vs 21% XOFF) which eats into throughput
4. **The trade-off:** autoclear keeps more paths active and reduces S4 drops, but the extra scheduler re-evaluation overhead on cosA costs more than it saves
5. **Both are clean** — zero anomalies, zero RTO/SACK, zero RX drops

**Why:** cos3 autoclear evaluation on SMC1/SMC2.
**How to apply:** autoclear reduces path disabled events but regresses BW 4%. The Q2 XOFF increase (21%→48%) suggests the scheduler overhead is the bottleneck. May need selective autoclear (cosB only, not cosA) or further tuning.
