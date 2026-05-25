# SMC Omega Sweep: Baseline (1.125.0-a-232) vs PR (#115606 + #115663)

**Date:** 2026-05-13
**Testbed:** smc1 (10.30.75.198) + smc2 (10.30.75.204), 8 Vulcano NICs each
**Baseline:** 1.125.0-a-232 (official)
**PR:** PR #115606 (tighten path inactivation + gate AI) + PR #115663 (AXI filter S4 priority)

## Summary: No Performance Regression

All IB and RCCL tests within ±2% at production message sizes (64K+).
write_with_imm shows **significant improvement** at small sizes with 8-32 QPs (baseline had near-zero BW).

## IB Aggregate BW at 8M (Gbps, bidirectional)

| Verb | ω | Baseline | PR | Delta |
|------|---|----------|-----|-------|
| write_bw | 5 | 740.4 | 737.5 | -0.4% |
| write_bw | 7 | 754.2 | 755.6 | +0.2% |
| write_bw | 10 | 760.8 | 761.8 | +0.1% |
| write_with_imm | 5 | 740.1 | 731.8 | -1.1% |
| write_with_imm | 7 | 754.3 | 756.1 | +0.2% |
| write_with_imm | 10 | 761.8 | 763.4 | +0.2% |

## RCCL Peak busBw (GB/s)

| Collective | ω | Baseline | PR | Delta |
|------------|---|----------|-----|-------|
| all_reduce | 5 | 358.51 | 355.94 | -0.7% |
| all_reduce | 7 | 362.22 | 361.54 | -0.2% |
| all_reduce | 10 | 361.82 | 361.91 | +0.0% |
| alltoall | 5 | 86.64 | 86.95 | +0.4% |
| alltoall | 7 | 88.05 | 88.16 | +0.1% |
| alltoall | 10 | 88.02 | 88.22 | +0.2% |
| alltoallv | 5 | 59.99 | 59.78 | -0.4% |
| alltoallv | 7 | 60.76 | 60.80 | +0.1% |
| alltoallv | 10 | 60.90 | 60.82 | -0.1% |

## Notable: write_with_imm Small-Size Fix

Baseline had near-zero BW at small sizes (1K-4K) with 8-32 QPs due to excessive
path removal churn. The PR fixes this:

| QP | ω | Size | Baseline (Gbps) | PR (Gbps) | Improvement |
|----|---|------|----------------|-----------|-------------|
| 16 | 5 | 1K | 0.34 | 46.46 | 137x |
| 16 | 5 | 4K | 1.34 | 184.15 | 137x |
| 16 | 7 | 4K | 1.34 | 84.38 | 63x |
| 16 | 10 | 1K | 0.33 | 43.08 | 131x |
| 16 | 10 | 4K | 1.34 | 172.76 | 129x |
| 32 | 7 | 1K | 0.50 | 48.84 | 98x |
| 32 | 7 | 4K | 2.01 | 192.14 | 96x |
| 32 | 10 | 1K | 0.66 | 27.57 | 42x |
| 32 | 10 | 4K | 2.67 | 109.01 | 41x |

---
Raw data: `/tmp/smc_baseline_ib_results.csv`, `/tmp/smc_pr_ib_results.csv`
RCCL logs: `/tmp/smc_sweep_baseline/`, `/tmp/smc_sweep_pr/`
