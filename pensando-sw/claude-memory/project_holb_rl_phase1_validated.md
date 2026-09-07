---
name: HOLB LLC-Meter RL Phase-1 validated (commit-ready)
description: Phase-1 HOLB rate-limiter validation on perf-3/perf-4 — RL recovers HOLB to line rate; path-1 9QP is cleanest proof (+34%)
type: project
originSessionId: 1418ad7a-e393-49d8-aa61-76d2bde9f02b
---
Vishwas's LLC Atomic Meter Rate Limiter (HOLB fix) validated commit-ready on kenya-perf-3↔perf-4 (4×200G, a-115-16), 2026-09-07.

**Why:** needed clean empirical proof the RL recovers head-of-line-blocking before commit.
**How to apply:** cite these results when RL/HOLB comes up; the driver scripts + lib are reusable for re-runs.

- **Report:** http://srv6.pensando.io/systest/agentq/phase1-holb-rl-pradeept/ (raw 1a/1b/1c result files + gen script alongside)
- **Scripts:** /tmp/phase1_lib.sh (shared lib: run_config, wait_bw_ready, rl_set, port_shut/up, measure), /tmp/run_1b.sh, /tmp/run_1c.sh, /tmp/gen_phase1_report.py. RL binary = /root/pradeept/nicctl_tot.bin, RL 191.5G/port burst 256000 window-lg2 4, RED byte at HBM 0x10164c800.

**Key results (bidir, ~1512 = 4-port line rate):**
- Cleanest HOLB proof = **path-1, 9 QP**: hot port XOFFs others to 128 → agg **1123** → RL → **1507 balanced (+34%)**. Same 9QP path-4 self-heals to 1521 (zero RL).
- 1c port-shut: RL restores survivors to exact N-port line rate (1135/756/378). Port-loss HOLB is **stochastic** (same cell 770↔1150) — RL makes it deterministic.
- path-4 self-heals **only with RCN on**; no-RCN+shut+sparse still collapses (860/622) → RL recovers.
- **omega is NOT the lever for structural path-1 HOLB** (ω5=ω7). The ω5-masks-HOLB effect is path-4 window-sizing (1a) only — does not apply to path-1/1c. So no ω-escalation was needed.
- **1024 QP works** (path-4: 1508/1505/1494 → 1513). Initial FAIL was a harness tuning bug: fixed `-t 32 -r 32` overflowed the combined send+recv CQ (`(TX+RX)×QP ≤ 65435` cap; 64×1024=65536 fails, 64×512=32768 ok — why 512 passed but 1024 didn't). Fix per /run-ib skill: TX/RX depth tiers (≥785 QP → 8/7), `--use_hugepages`, `--noPeak` at ≥512. start_traffic in phase1_lib.sh updated.
- **Genuine no-connect edges (NOT RL, NOT tuning):** QP33+1-survivor (path-1 strands ~25/33 QPs on dead ports) and 512QP+port-shut (admin-down destabilizes 512-QP bringup; 512 no-shut = 1509 ok). Neither affects RL conclusion — path-4 self-heal under port loss already shown at QP9 (859→1135) & QP63.

Testbed: perf-3 10.30.52.66 (sender) ↔ perf-4 10.30.52.75 (recv), BDF 0000:c1:00.0, rocep195s0f3, planes 19.1-4.0.2/.1. Left clean (RCN ω5, path-4, RL off, ports up, state cleared).
