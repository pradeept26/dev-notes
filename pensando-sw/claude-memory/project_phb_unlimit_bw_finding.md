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
- **10-bit PCIe tags don't change it**: with tags ON, C0 default=1395.76, C1 unlimit=913 (poke
  still hurts -35%, TXS XOFF high both ends). 10-bit tags reset off by any reboot/card-reset;
  re-enable via /root/nbatchu/10bit_tags_hydra.py (setpci -s c3:00.3 CAP_EXP+28.w=1000).
- **Full 2x2 matrix (tags on, 4000QP@8M):** RCN-on/default=1395.8 (BEST); RCN-on/unlimit=913;
  RCN-off/default=1073.7; RCN-off/unlimit=858.9 (WORST). RCN helps in both cases (+~30%/+6%);
  poke hurts in both cases (-35%/-20%). Best is always plain default + RCN.
- common.sh QoS also HURTS 4000QP here: min-rto 1000 = -23% (dominant), DSCP classification
  = -8% extra. Both degrade; default (PCP, min-rto 75) is best. DSCP classification is sticky
  (survives card reset); min-rto resets to default 75 on card reset.
- These Kenya perf nodes have unreliable PCIe link-training after reboot/BMC-reset (perf-11
  came up Gen5 once, perf-12 came up Gen1 once -> ~42G) and perf-11 has a persistent ACPI
  gpe1F storm (mask via: echo disable > /sys/firmware/acpi/interrupts/gpe1F). 4000QP load
  hard-crashed perf-12 (host+BMC) once. Verify Gen6 (lspci c3:00.3 LnkSta 64GT/s) before tests.

## Mechanism: unlimit deepens PHB -> inflates PCIe + network latency (why it hurts)
- **PCIe read latency** (nicctl show pcie internal latency-bucket -r): at default perf-12's
  5-7.5us bucket = 0; with deep PHB (unlimit or pipeline_max=max) it lights up (569K-892K on
  4000QP; 27K on 8QP). Only perf-12 (client) shows it; perf-11 (server) stays <2.5us. => the
  5-7.5us bucket is a good early "perf degrading" indicator; perf-12 host/PCIe is the weak side.
- **Network RTT** (nicctl show rdma queue-pair path statistics -> RTT buckets 0-25/25-50/50-75/
  >75us + Min/Max RTT; 8QP bidir, RCN on): default min4/max~55us, ~0.28% in 25-50us bucket;
  unlimit min4/max~68us, ~1.5% in 25-50us (~5x). So unlimit modestly inflates RTT (deeper
  queueing/bufferbloat).
- **BUT RCN does NOT react**: ECN=0, CNP=0, QP CWND ~50, congestion state "aimd" in BOTH configs
  on 8QP. The RTT rise is too small to trigger CC; CWND unchanged. So the added latency just
  costs BW with no CC compensation: 8QP bidir default ~1450 -> unlimit 1246.
- pipeline_max is additive to total_credit: PM=max(0x3fff) with default credits let OQ3 depth
  reach ~4500-5800 (> total_credit 3056); full unlimit (big pools) reaches ~14-16K.

## SWEET SPOT (best config): small PHB poke total<=0x1000 + omega=10 = line rate (perf-11/12)
There's a sharp threshold in total_credit for the omega needed (8-QP @8M, paths=8, RCN on):
- total<=0x1000 (4096): line rate at **omega=10**. default(0xbf0)=1522, P1(0xe00)=1524, **P2(0x1000)=1527**.
- total>=0x1400 (5120): needs **omega=20** (P3 0x1400: om10=1382, om15=1490, om20=1522).
- full unlimit (0x3f00): needs omega=20, and only ~1478-1516.
**Sweet spot = P2: pipeline_max=0x400 per_cls=0x800 common=0xa00 total=0x1000, omega=10-15.**
Full-matrix validation (all QP 2-64 x 64K/1M/8M): P2+omega=15 hits line rate (~1515-1538)
EVERYWHERE except 64K@2-4QP (1229-1423, inherent small-msg/low-QP limit, unfixable by any
PHB/omega config; default also ~1237 there). omega=10 covers QP>=8; omega=15 also covers QP2/4
large-msg + a QP16@8M dip. **omega=20 NOT needed for P2** (only the big unlimit pools forced ω=20).
Across QP @8M: QP2=1498, QP8=1528, QP32=1529, QP64=1524 (line rate, best in study). This is a
modest poke (~1.3x default total) that hits line rate at LOW omega — no need for the big unlimit
pools + omega=20. (default PHB + omega=10 also reaches line rate and is simplest; P2 is marginally
higher at 8-32 QP.) Bigger pools just force higher omega with no benefit.

## Line rate WITH unlimit PHB = raise omega to ~20 (perf-11/12, paths=8, RCN on, 8-QP)
Unlimit PHB needs a HIGHER omega than default because its deeper staging => higher RTT =>
QWND_max=gamma*rate*(RTT+omega*8) needs bigger omega to fill the pipe.
- unlimit PHB, omega sweep (8-QP bidir, -n5000): 5=1362/1373, 7=1393/1399, 10=1399/1404,
  15=1395/1403, **20=1478(8M)/1516(1M)** <- breakthrough. omega 5-15 plateau ~1360-1404; ω=20
  jumps to ~line rate. At ω=20: CWND ~111, ECN/CNP=0, max RTT 78us. 8M ~1450-1478 (near line
  rate; may need ω~22-25 for full 1520). Contrast: DEFAULT PHB reaches line rate at only ω=10.
- So "line rate with unlimit" IS achievable by omega alone (~20), no other field needed — the
  user was right. Default PHB + ω=10 is still simpler/cleaner for the same line rate.

## THE REAL FIX for the low-QP dip: omega (CC window), NOT PHB (perf-11/12, paths=8, RCN on)
`nicctl update pipeline rdma congestion-control profile --profile-id 0 --omega <v>` (not
persistent; reapply after reboot). QWND_max = gamma*TargetRate*(RTT + omega*8) — higher omega =
bigger CC window = more in-flight. Profile default was omega=5; nicmgr code default is 10.
- **8-QP bidir @8M/1M, default PHB:** omega 5->7->10 = **1378 -> 1432 -> 1522 G (+10.5%, line
  rate!)**, plateaus at 10 (10/12/15/20 all ~1522). CWND ~50 (om5) -> ~87 (om10); ECN/CNP=0;
  max RTT 55->85us (more in-flight, NOT congestion). The low-QP dip was the CC window cap, not PHB.
- omega=10 also holds line rate at 32/64 QP (1523/1520) — no downside on this 2-node pair (no
  ECN storm; that only bites large-fabric N×N per the ref). So omega=10 gives line rate across
  ALL QP counts 8-64 here, vs omega=5 which only reached it at 32-64.
- **Recommendation: omega=10** for this few-flow/ring-like workload (ref: mixed=7, alltoall=5,
  allreduce=10). This is the lever to use, NOT the unlimit PHB poke (which hurts, see below).

## Path-count dependence (8-QP bidir @8M, RCN on) — multipath fixes the unlimit degradation
- **paths=2:** default ~1450 -> unlimit **1246 (-14%)**; unlimit max RTT 68us, 25-50us bucket 1.5%.
- **paths=8:** default 1373 -> unlimit **1366 (~equal)**; unlimit max RTT 55us, 25-50us bucket 0.11%.
- => unlimit's harm is path-count dependent: at low path count deep staging concentrates on few
  paths -> per-path queueing/RTT inflation -> BW loss. At 8 paths the load spreads, per-path
  queueing stays shallow, RTT stays tight, and unlimit is benign. Multipath is the real mitigation.

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
