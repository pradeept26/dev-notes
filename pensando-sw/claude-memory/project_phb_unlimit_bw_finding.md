---
name: PHB poke improves 4000QP BW only from a fresh host reboot
description: TX-scheduler PHB tuning (unlimit_phb / pipeline_max / credit pools) improves 4000QP@8M IB-write BW on Kenya 800G ONLY from a cold host reboot (~+9%); on a warm/primed host it is a no-op. Host-boot state is the confounder.
type: project
originSessionId: 27c799a2-3e3f-471f-9b4a-8a63ed2c12ac
---
# PHB tuning improves 4000QP BW — but ONLY from a fresh host reboot (Kenya perf-3/4, 800G, 1.130-a)

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
