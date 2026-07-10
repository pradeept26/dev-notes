---
name: PHB poke effect is boot-state AND path dependent (helps perf-3/4, hurts perf-11/12)
description: TX-scheduler PHB tuning (unlimit_phb / pipeline_max / credit pools) at 4000QP@8M on Kenya 800G is NOT a universal win. Cold perf-3/4 (direct path) it recovers +9%; cold perf-11/12 (switched N2-N3 path) it DEGRADES -31% via TXS backpressure. On a warm host it's a no-op.
type: project
originSessionId: 27c799a2-3e3f-471f-9b4a-8a63ed2c12ac
---
# PHB poke: boot-state AND path dependent — NOT a universal win (Kenya 800G, 1.130-a)

## 2nd node pair (perf-11/12, switched N2<->N3 path) — 2026-07-10: poke HURTS
Freshly booted (cold), FW 1.130.2-a-3, RCN on, paths=2, hugepages=65536. 4000QP bidir @8M.
capview uses `-c` (not `-x`) on these nodes. UUIDs: perf-11 ...384143..., perf-12 ...384130...
(perf-12 RDMA dev is `ionic_0`, perf-11 `rocep195s0f3`).

| Cfg | PM | pools | BW | total_used | perf-12 TXS CoS3 XOFF |
|-----|----|-------|----|-----------|-----------------------|
| C0 default | 0x0 | 7d0/640/bf0 | **1395.8** | ~1150 | **0%** |
| C3 PM-only | 0x2100 | default | 1073.6 | ~1900 | 9-14% |
| C1 unlimit | 0x2100 | big | ~960 (953/970) | ~8800 | 74-87% |
| C2 credits-only | 0x0 | big | 912.9 | ~6470 | 85-88% |

**Monotonic: deeper PHB occupancy -> more perf-12 TXS backpressure -> lower BW.** Default is
best; credit pools hurt most (-31%), pipeline_max hurts less. On the switched perf-11/12 path,
filling the NIC PHB deep overruns the path and the scheduler XOFFs, throttling. This is the
OPPOSITE of perf-3/4 (direct path) where deeper PHB fed the port and helped.

**=> The poke's sign depends on the path/topology.** Direct/short path (perf-3/4): can help
from cold. Switched/longer path (perf-11/12): hurts. Do NOT apply unlimit_phb blindly — it can
degrade BW. Watch far-end TXS CoS3 XOFF; if the poke drives it high, it's hurting.

### perf-11/12 extra facts (2026-07-10)
- **8-QP bidir @8M = ~1510 G (near line rate); 4000-QP default = ~1342-1395 G** — a real ~11%
  high-QP dip on this switched path, NOT a PHB problem (poke makes it worse). Same current state,
  only QP count differs.
- **Card reset does NOT lift the 4000-QP number** (1342 post-card-reset vs 1395 before — flat).
  Earlier hunch "card reset = the fix" was WRONG: the 8-QP=1510 vs 4000-QP=1342 gap is QP-scaling,
  not card-reset. So the high-QP ceiling is path-dependent (~1500 direct perf-3/4, ~1350-1400
  switched perf-11/12) and its cause at 4000QP is still open (switch headroom / QP sched / CC).
- RCN helps here more than perf-3/4: 4000-QP default 1083 (RCN off) -> 1395 (RCN on), +29%.

---
# perf-3/4 (direct path): PHB poke helps from cold, no-op when warm

**Bottom line (corrected 2026-07-09):** Whether the PHB poke helps depends on **host boot
state**, which is why results looked contradictory:

- **Fresh host reboot (cold, representative of production start):** default PHB caps 4000 QP
  bidir @ 8M at **~1396 Gbps**; the poke recovers it to **~1503–1531 Gbps (~+9%)**. Original
  hypothesis HOLDS here.
- **Warm/primed host (long uptime, many prior poke runs in-session):** default already reaches
  **~1503 Gbps**; the poke is a **no-op**. This warm state is NOT representative — an earlier
  "poke is useless" conclusion was measured here and was misleading.

## Post-reboot ablation (card reset + host reboot both nodes, RCN on, hugepages=193345, paths=2)
Registers set BEFORE each run via `capview fset sch_cfg_flow_ctl_0/1`; each point a fresh ib run.

| Config | pipeline_max | per_cls/common/total | BW | free_common min | total_used peak |
|--------|----|----|----|----|----|
| default | 0x0 | 7d0/640/bf0 | **1395.8** (x3, rock-stable) | ~768 | ~1150 |
| credits-only | 0x0 | 2000/3000/3f00 | **1504.96** | ~6115 | ~6450 |
| pipeline_max-only | 0x2100 | 7d0/640/bf0 | **1503.17** | 0 | ~1930 |
| full unlimit | 0x2100 | 2000/3000/3f00 | **1514–1531** | ~3800 | ~8750 |

**Either lever alone recovers it** — raising pipeline_max OR the credit pools independently
lifts 1396 → ~1503. Mechanism: at post-reboot default, PHB occupancy caps ~1150 of 3056
available (pipeline underfed); either raising pipeline_max (occupancy→1930, free_common→0) or
the pools (occupancy→6450) unblocks the feed to the egress port. Default's 1396 is stable
across 3 runs over several minutes → NOT warm-up; it's a persistent cold-boot state.

## Open question (mechanism)
Same default `sch_cfg_flow_ctl` register gives 1396 cold vs 1503 warm — so a *non-flow_ctl*
state variable (cleared by host reboot, survives `nicctl reset card`) interacts with it.
Suspects: driver-side scheduler/QP init, hugepage physical layout, or residual scheduler/CC
state trained by prior high-credit traffic. Not yet isolated.

## How to apply
- If validating 4000 QP line rate, test from a **fresh host reboot** — a warm host hides the
  problem. From cold boot the default PHB is ~9% below line rate; apply the poke (either
  pipeline_max≥~0x800 OR larger credit pools) to recover.
- Also note RCN is worth ~+3.4% independently (1453→1503 warm; on cold boot RCN defaults OFF).

Poke scripts: `/root/vishwas/unlimit_phb.sh`, `limit_phb.sh` on perf-3/4 (both set
dyn_share_en=1, dyn_alpha=0, private=0xf0; differ only in pipeline_max + 3 credit pools).
Card UUIDs: perf-3 42424650-4632-3630-3430-303134000000, perf-4 …303031000000.
