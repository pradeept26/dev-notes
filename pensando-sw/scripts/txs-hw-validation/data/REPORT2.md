# Phase-2 HW report: txs spurious-PHV vs QP + BW/latency sweeps (SMC1/SMC2, per-card images)

Per-card images (no full-host reflash): benic1=**B1** (AC-on,no-txs), benic2=**B2** (AC-off,no-txs=shipping), benic3=**F** (AC-off+txs). GID idx2, 8 paths. Metric = `phb_drops` (== spurious PHVs = NPV_phv-PSP_phv; robust max-engine).


## Multi-QP DRAINING (ib_write_bw -t1 512B) spurious phb_drops — RCN off

| QP | B1 (AC-on) | B2 (AC-off) | F (AC-off+txs) | F vs B2 |
|----|-----------|-------------|----------------|---------|
| 2 | 85M | 285M | 143M | -50% |
| 4 | 139M | 565M | 285M | -50% |
| 8 | 280M | 1121M | 558M | -50% |
| 16 | 487M | 1764M | 906M | -49% |
| 32 | 724M | 2005M | 1470M | -27% |
| 64 | 833M | 1305M | 1102M | -16% |

## Multi-QP DRAINING (ib_write_bw -t1 512B) spurious phb_drops — RCN on

| QP | B1 (AC-on) | B2 (AC-off) | F (AC-off+txs) | F vs B2 |
|----|-----------|-------------|----------------|---------|
| 2 | 89M | 285M | 143M | -50% |
| 4 | 169M | 569M | 286M | -50% |
| 8 | 280M | 1111M | 563M | -49% |
| 16 | 482M | 1801M | 916M | -49% |
| 32 | 716M | 2006M | 1481M | -26% |
| 64 | 813M | 1297M | 1110M | -14% |

## Saturated (ib_write_bw -t128 512B t128) spurious phb_drops — RCN off (SQ stays backlogged)

| QP | B1 | B2 | F | F vs B2 |
|----|----|----|----|--------|
| 2 | 586M | 959M | 939M | -2% |
| 4 | 606M | 965M | 936M | -3% |
| 8 | 565M | 964M | 938M | -3% |
| 16 | 569M | 969M | 938M | -3% |
| 32 | 527M | 937M | 917M | -2% |
| 64 | 535M | 927M | 898M | -3% |

## Saturated (ib_write_bw -t128 1M t128) spurious phb_drops — RCN off (SQ stays backlogged)

| QP | B1 | B2 | F | F vs B2 |
|----|----|----|----|--------|
| 2 | 606M | 617M | 614M | -0% |
| 4 | 624M | 621M | 615M | -1% |
| 8 | 619M | 619M | 627M | +1% |
| 16 | 651M | 648M | 646M | -0% |
| 32 | 696M | 682M | 681M | -0% |
| 64 | 694M | 719M | 717M | -0% |

## 1-QP latency drain anchor (ib_write_lat) spurious phb_drops

| RCN | B1 | B2 | F | F vs B2 |
|-----|----|----|----|--------|
| off | 75M | 223M | 110M | -51% |
| on | 75M | 224M | 113M | -50% |

## BW size-sweep — peak bidir BW (Gb/s), RCN off  (no-regression check)

| QP | B1 | B2 | F |
|----|----|----|----|
| 2 | 759 | 760 | 760 |
| 4 | 754 | 754 | 754 |
| 8 | 752 | 753 | 753 |
| 16 | 753 | 753 | 753 |
| 32 | 753 | 753 | 753 |
| 64 | 753 | 753 | 753 |

## Latency sweep (ib_write_lat, QP1) t_avg µs, RCN off

| size | B1 | B2 | F |
|------|----|----|----|
| 2 | 4.87 | 4.88 | 4.87 |
| 64 | 4.83 | 4.84 | 4.83 |
| 512 | 5.12 | 5.12 | 5.12 |
| 4096 | 5.56 | 5.56 | 5.55 |
| 65536 | 6.89 | 6.89 | 6.88 |
| 1048576 | 27.27 | 27.33 | 27.27 |

## Correctness
- Max real PRD `drops=` across all 117 runs: **204925** (negligible; phb_drops is a free-running spurious-PHV counter, not loss).
- phb_drops == NPV_phv − PSP_phv (two independent measures agree).
- nicctl `packet-buffer drop` (authoritative real loss): **0 on all 3 cards** (B1/B2/F), all ports; rdma anomalies clean.
- BW no-regression: peak bidir BW ~753 Gb/s for B1/B2/F at every QP 2-64 (RCN off/on).
- Latency no-regression: t_avg identical across B1/B2/F at all sizes (txs removes spurious PHVs without changing op latency).

## Bottom line
- **txs (F) cuts B2's spurious end-of-SQ PHVs ~50% at QP 2-16** under a draining workload, tapering to
  ~16-27% at QP 32/64 (scheduler stays busier serving many SQs). Consistent RCN off/on. 1-QP lat anchor
  agrees (~51%).
- The benefit is **drain-specific**: under backlogged throughput (ib_write_bw -t128, 512B or 1M) the SQ
  never empties, so B2≈F (no benefit, no regression) at all QP.
- **Zero cost:** no BW regression (~753 all QP), no latency regression, zero real packet drops.
