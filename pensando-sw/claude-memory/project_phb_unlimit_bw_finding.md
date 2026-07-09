---
name: PHB unlimit poke does not affect 4000QP BW
description: Experimental finding — TX-scheduler PHB credit tuning (unlimit_phb.sh) has zero effect on 4000QP@8M IB-write BW on Kenya 800G; refuted hypothesis
type: project
originSessionId: 27c799a2-3e3f-471f-9b4a-8a63ed2c12ac
---
# PHB credit tuning does NOT improve 4000 QP IB-write BW (Kenya perf-3/4, 800G, 1.130-a)

**Finding:** On a clean setup (card reset → bringup → registers set *before* traffic), 4000 QP
bidir IB-write @ 8M holds a flat **~1503 Gbps across the entire PHB config space**. The
`unlimit_phb.sh` poke is a **no-op** for BW.

Verified 2026-07-09 via controlled ablation on `sch_cfg_flow_ctl_0/1` (fields: pipeline_max,
per_cls_credit, common_credit, total_credit, dynamic_share_en):
- C0 true default (PM=0, per_cls=0x7d0, common=0x640, total=0xbf0, dyn_share=1): 1503.19/1503.17 G; `free_common` floors ~764 (pool 1600, never saturated)
- C1 full unlimit (PM=0x2100, 0x2000/0x3000/0x3f00): 1503.15/1503.10 G; free_common ~3800 headroom
- C4 dynamic_share_en=0 (default credits): 1503.38 G even with **free_common=0 (pool fully exhausted)**
- pipeline_max 0x0 vs 0x800 (earlier clean A/B): both 1503 G

**Why:** even driving the PHB common pool to 0 (C4) doesn't drop BW → PHB is definitively NOT
the 4000QP@8M throughput limiter. `phb_drops` are present in all configs (~1–4 M/s, higher
with bigger pools) but non-limiting. TXS CoS3 XOFF = 0% throughout.

**Root cause of earlier false "improvement" (1411→1522):** measurement artifact — registers
were poked mid-run on non-fresh state, and baselines weren't taken after a clean card reset.
A clean card reset alone yields line rate.

**Why:** avoids re-running this experiment; the PHB/credit hypothesis for 4000QP line-rate is
closed. **How to apply:** if 4000QP BW looks low, first do a fresh card reset + bringup and
re-measure before touching PHB registers. Residual gap vs 8-QP peak (1503 vs ~1541 G, ~2.5%)
is unrelated to PHB — chase via CC/RCN or QP-scheduling, not credits.

Poke scripts: `/root/vishwas/unlimit_phb.sh`, `limit_phb.sh` on perf-3/4 (both set
dyn_share_en=1, dyn_alpha=0, private=0xf0; only differ in pipeline_max + 3 credit pools).
