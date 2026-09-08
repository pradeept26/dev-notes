# Session Handoff — HOLB / LLC-Meter Rate-Limiter Validation (Sep 2026)

**Owner:** Pradeep · **Testbed:** kenya-perf-3 ↔ perf-4 (Vulcano AI-NIC) · **Firmware:** 1.130.0-a-106-82 (pic_rl/RL build)
**Goal:** validate Vishwas/gborcar's **LLC Atomic Meter Rate Limiter (RL)** as the fix for RDMA
head-of-line-blocking (HOLB), across 4×200G, 8×100G, and 2×400G port profiles, and get it commit-ready.

> **TL;DR:** RL is **commit-ready on 4×200G and 2×400G** — it recovers every survivable HOLB to
> line rate. On **8×100G it's broken** (RL hardcoded for 4 ports; ports 4–7 blocked → half BW) —
> needs a code fix from gborcar (not tunable). For 2×400G, **RCN omega 7 + RL** reaches line rate at
> all QP and fixes HOLB. Two published reports + a testbed runbook (see §8).

---

## 1. Testbed & access
| Node | Role | Mgmt IP | Creds |
|------|------|---------|-------|
| perf-3 (kenya-1354, FPF26040014) | client/sender | 10.30.52.66 | root/docker |
| perf-4 (kenya-3190, FPF26040001) | server/receiver | 10.30.52.75 | root/docker |

- BDF `0000:c1:00.0`, ASIC vulcano, RDMA dev `rocep195s0f3`, base netdev `enp195s0f3`.
- BMC perf-3: 10.30.52.61 `admin`/`Pen1nfra$` (**ipmitool `-I lanplus -C 17`**). APC PDU 10.30.52.57 port 19.
- RL-capable host binary: `/root/pradeept/nicctl_tot.bin` (stock nicctl lacks the `debug … rate-limit` cmds).
- **Full testbed runbook:** `~/dev-notes/pensando-sw/kenya-2x400-handoff.md` (flash/bringup/IB/RL details).

---

## 2. How the RL works (mental model)
- Per-port **token-bucket meter** in HBM (region `pic_rl_meters`, 64 B/entry). Caps each port at
  `--rate-bps` (≈95.75 % of per-port line rate). Programmed by nicmgr `rdma_pic_rl.c`.
- **RED status byte at HBM `0x10164c800`** — 8 bytes, `byte[i]=1` ⇒ port i is being throttled.
- RL is a **ceiling, not a floor** — it can only *slow* an oversubscribed port, not *speed up* an
  under-driven one. It fixes HOLB by capping the aggressor port *before* its buffer overflows/XOFFs,
  which releases the backpressure starving the other ports.
- Config knobs: `--rate-bps --burst-bytes --window-lg2 --max-ports --lif`. On 4×200G/2×400G the RDMA
  traffic lif = **hw_id 1** (was **18** on the older 4×200G notes — verify with
  `nicctl show rdma queue-pair | grep -i lif`).

---

## 3. Phase-1 validation on 4×200G  →  **REPORT:** http://srv6.pensando.io/systest/agentq/phase1-holb-rl-pradeept/
Config: path-4 (or path-1 for HOLB), active-path **disabled** (Meta's setting), RL 191.5 G/port, max-ports 4.

- **1a — QP sweep (path-4, 8→1024):** path-4 self-balances; mild HOLB at 64 no-RCN / 128–512 ω7 →
  RL pins all to ~1513. **1024 QP needed a perftest fix** — fixed `-t32 -r32` overflowed the combined
  CQ (`(TX+RX)×QP ≤ 65435`; 64×1024=65536 fails, 64×512 ok). Fix: per-QP TX/RX tiers (≥785 QP → 8/7),
  `--use_hugepages`, `--noPeak` at ≥512.
- **1b — sparse/odd QP:** cleanest HOLB proof = **path-1, 9 QP** — hot port's XOFF starves the others
  to 128 (agg **1123**) → RL → **1507 balanced (+34%)**. Same 9 QP on path-4 self-heals to 1521 (no RL).
  HOLB worst at sparsest oversubscription (3/2/2/2), vanishes as QP grows. **ω5≈ω7≈no-RCN** (structural
  port-mapping HOLB, not window-sizing). High-QP (511/729/1023) = clean round-robin, no HOLB.
  **path-4 contrast (7→1023):** low QP RCN *limits* (ω5 caps 1398; ω7/no-RCN hit line rate); mid/high QP
  **no-RCN has systematic mild HOLB** (uncontrolled windows oversubscribe one port, RTT→24µs) → RL fixes.
  So "path-4 self-heals" is really "*RCN* self-heals."
- **1c/live-shut sweep — full matrix (path-4, QP 8→1024 × RCNω5/ω7/noRCN × shut 1/2/3):** shut the port
  **during running traffic** (all QPs connect first) — the correct method; pre-connect shut hits
  connection artifacts (QP33+1-survivor stranding, 512+shut multiplane-perftest limit). **RL restores
  survivors to exact N-port line rate (1135/756/378), 18 rescue cells.** Port-loss HOLB is *stochastic*
  (770↔1150); RL makes it deterministic. **1024 no-RCN + live 2-port shut can HANG the host** (memory
  pressure from uncontrolled windows + stalled QPs) — recovered via BMC power-cycle; a stress corner.

### 3b. Deep-dive root causes (all in the report)
- **1024 shut-2 lands ~720 not 757:** with `active-path-per-path-group=disabled`, the 2 survivors don't
  balance — active-path skew **729 vs 388 (1.88:1)**; hot port saturates+RL-capped, cold port under-driven
  (RED=0). Enabling active-path → 198/198 → 756. **Skew is deterministic — lowest-index survivor always
  wins** (7 consistent runs; shut{2,3}→port0 wins). Same skew at 512 but RL recovers there (226 paths
  clears the saturation bar; 388 at 1024 falls just short due to thinner per-path rate).
- **Code root cause (P4):** it's *congestion-driven path inactivation*, not link-down failover.
  `rx/meta_roce_rx_s2.p4:47` `_should_path_be_kept_active` — active-path=0 keeps only **path_id 0**;
  `include/rdma_util.h:88` maps path 0 → lowest-index port; `rx_s3.p4:195` removes any `cwnd≤0` path.
  → keep `active-path-per-path-group` **enabled** for multiplane fault tolerance (Meta wants it off).

---

## 4. 8×100G  →  **RL IS BROKEN (4-port hardcode)**
Reflashed `meta-roce-8x100G-1`. Datapath fine (1533 balanced across 8 ports without RL). **With RL,
ports 4–7 are driven to zero → ~half BW.**

- **Root cause (definitive, code):** the RL's per-port **recovery ("peek")** logic is hardcoded for
  ports 0–3 (`pic_rl_meter_peek_port0/1` in `tx_s4.p4:240/288`, `port2/3` in `tx_s3.p4:645/687`; the
  ud0/ud1 predicate split in `tx_s1.p4:775` only assigns ports 0–3). Ports 4–7 get *throttled* by the
  meter (RED=1) but there's **no peek to ever un-block them** → permanently stuck at TX=0. The throttle
  side, meter region (512 B = 8 entries), nicmgr, and 8-bit status bitmap are already 8-port ready —
  **only recovery is 4-port.** Independent of `window-lg2` (4 vs 10 identical) → **NOT tunable.**
- **Fix needed (contained):** add `pred_peek_port4–7` (PHV, `tx_phv.p4:187`), extend the ud0/ud1 split
  in `tx_s1.p4:775`, add 4 peek actions + tables (base = `pic_rl_meters + N×64`) + apply calls, spread
  across stages for TCAM budget; bump the commented debug region from +256 to +512. Main risk = TX
  pipeline resource budget for 4 more peek tables.
- **Owner = gborcar** (branch `gborcar/meter_rl_llc_new`; latest commit 2026-09-03 explicitly "Support
  4 ports"). **No 8-port work in any branch.** Gaurav owns the testbed bringup scripts, not the RL.
- **8×100G reflash gotchas:** `m8setup.sh` off-by-one (hardcodes enp197–204; actual enp196–203) →
  use `/tmp/m8fix.sh`. RDMA lif = 1. 8 planes need settle time before reading BW.

---

## 5. 2×400G  →  **VALIDATED**  →  **REPORT:** http://srv6.pensando.io/systest/agentq/holb-2x400-pradeept/
Reflashed `meta-roce-2x400G-4` (2 ports = inside the RL's working 0–3 range → **4-port bug doesn't apply**).

- **1a (path-2):** self-balances; **ω5 caps low-QP (q8=1373); ω7/no-RCN hit line rate**; RL holds ~1515.
- **1b (path-1 HOLB):** QP split uneven (q9 = 5/4), hot port XOFFs the other to 207–339 →
  **RL recovers every cell to 1515, balanced 384/384** (+29% at q5). Path→port maps confirm mechanism.
  path-2 contrast self-balances (1533, RL idle).
- **Live-shut (2→1):** survivor → 757 = 1-port line rate; RL idle (single survivor, no HOLB); restore ramps back.
- **RCN tuning (key ask): ω7 is the answer** — reaches line rate at every QP (ω5 caps low QP; ω10 no extra
  benefit; window-shift/pwnd tweaks don't help — omega is the lever). **ω7 + RL = 1515 balanced + HOLB
  fixed** (vs ω5+RL = 1500). **→ Recommended 2×400G config: RCN on, omega 7, active-path disabled, + RL
  (383 G/port, max-ports 2).**
- One transient to re-verify: p1-q63 ω7 RL-on read 972 once (all other q63 = 1515).

---

## 6. Bugs / issues found this session
| # | Issue | Status |
|---|-------|--------|
| 1 | **RL hardcoded 4 ports — ports 4–7 blocked on 8×100G** (peek recovery missing) | Code fix needed → **gborcar** |
| 2 | RCN **omega 5 caps low-QP throughput** (all profiles) — use omega 7 | Tuning: use ω7 |
| 3 | 1024-QP no-RCN + live multi-port shut can **hang the host** | Stress corner; keep CC on at extreme QP |
| 4 | perftest CQ overflow at high QP with fixed TX/RX (`(TX+RX)×QP>65435`) | Harness fixed (per-QP tiers) |
| 5 | 512-QP + pre-connect port-shut / subset `--planes` fail (multiplane perftest limit) | Use **live** shut instead |
| 6 | `m8setup.sh` device off-by-one; hugepages lost on reboot; RDMA lif=1 not 18 | Documented in runbook |
| 7 | 2×400G p1-q63 ω7 RL-on 972 transient | Re-verify |

---

## 7. Reports & raw data (on srv6 / `/vol/systest/agentq/`)
- **4×200G Phase-1:** `phase1-holb-rl-pradeept/` — index.html + phase1a/b/c, live_prog, path dumps, gen scripts.
- **2×400G:** `holb-2x400-pradeept/` — index.html + sweep_1a/1b, rcn_tune, liveshut, pd_* path dumps.
- Reports regenerate from result files via the `gen_*_report.py` in each dir.

## 8. Scripts / harness (in `/tmp`, reusable)
- `phase1_lib.sh` — shared lib (run_config, wait_bw_ready, qp_txrx TX/RX tiers, rl_set, port_shut/up, measure, start_traffic).
- 4×200G: `run_1b.sh`, `live_prog.sh` (progressive live-shut), `cap_*` (path-dump capture), `parse_paths.py`, `plane_probe.sh`.
- 8×100G: `m8fix.sh` (corrected bringup), `gen_live_report.py`.
- 2×400G: `m2fix.sh`, `sweep_1a_2x400.sh`, `sweep_1b_2x400.sh`, `liveshut_2x400.sh`, `rcn_tune_2x400.sh`, `gen_2x400_report.py`.
- Testbed runbook: `~/dev-notes/pensando-sw/kenya-2x400-handoff.md`.

## 9. Key learnings / gotchas
- RL is a **ceiling not a floor**; fixes oversubscription HOLB, can't raise a demand-starved/under-pathed port.
- **path-1 = HOLB generator** (QP pinned to one port); **path-4/path-2 self-heal *with RCN*** (no-RCN can still HOLB).
- **active-path-per-path-group disabled** → deterministic lowest-index-survivor skew under multi-port loss.
- **omega 5 too conservative at low QP → use omega 7.** ω is the only lever that matters for the low-QP ceiling.
- Multiplane perftest: connect via **mgmt IP**; `--planes` = full plane set; **live-shut** beats pre-connect shut; 8-plane needs settle time.
- Hugepages reset on reboot; Kenya nodes sometimes need a **power-drain (off→on)** to re-train PCIe.

## 10. Open items / next steps
1. **8×100G RL fix** — hand the §4 change list to gborcar; re-test 8×100G once peek_port4–7 lands.
2. **Re-verify** the 2×400G p1-q63 ω7 RL-on 972 transient.
3. Optional: 4×200G active-path-**enabled** confirmation pass (Meta wants it disabled, so low priority).
4. File Jira(s) for #1 (RL 4-port) and #3 (host hang) if the team wants them tracked.
5. Testbed currently on **2×400G, RCN ω7, RL off, ports up** (clean). Runbook at `kenya-2x400-handoff.md`.

---
_Compiled 2026-09-08. Memory entries: `project_holb_rl_phase1_validated.md`, `reference_kenya_perf3_recovery.md` (in the Claude project memory dir)._
