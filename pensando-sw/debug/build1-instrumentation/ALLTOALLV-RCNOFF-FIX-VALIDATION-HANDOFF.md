# Handoff — alltoallv RCN-off QP-window-collapse hang: fix, validation & results

**Author:** Pradeep Thangaraju (via Claude)
**Last updated:** 2026-07-23
**Platform:** Vulcano / Hydra / Meta RoCE, base **1.130.2-a-4** (commit `da4d25d29db`)
**Testbed:** GT 2-node (GT-1 `10.30.69.101`, GT-4 `10.30.69.98`), 8×Vulcano/node, 4×100G, path count 8
**Related PR:** #118783 `vishwas/alltoallv-rcnoff-cwnd-collapse-fix`
**Supersedes/extends:** `ALLTOALLV-RCNOFF-FIX-HANDOFF.md` (build/ablation) and `../build1-run-20260722-082342/{RESULTS,FIX-ABLATION}.md`

---

## 0. TL;DR & recommendation

- RCCL **alltoallv with RCN disabled HANGS** on GT Vulcano (~50% of runs, baseline a-4). One QP's
  congestion window (`qwnd`) collapses to 0 and its paths strand → the all-pairs collective deadlocks.
- **Root cause (counter- + code-confirmed):** disabled paths that drain at `cwnd<=0` are **stranded**
  (neither re-enabled nor demoted to inactive), inflating `num_active_path` so bootstrap can't recover;
  combined with `qwnd→0` (via the unfloored `force_inactivate` subtract) both bootstrap triggers die.
- **Recommendation: ship Fix A only** (the rx_s3 disabled→inactive demotion). PR #118783 also carries
  **Fix B** (`tx_s2` `qp_cwnd==0` bootstrap trigger); our data shows **Fix B is redundant** when Fix A
  is present — with Fix A, `qwnd` never reaches 0 (`forceinact=0` across 30+ runs), so Fix B never fires.
- **Validation (all on Fix-A image):** **30/30 clean** stress soaks (10× 16G×1000 + 20× sweep) with
  heavy stranding stress and **zero stranded paths**, plus a **5-collective RCN-on/off** and
  **SACK immediate/window-delay** sanity — all no-hang. Baseline hangs ~50%.
- **Separate, independent bug found:** `qp_err_dis_va_no_page` error-disable during long alltoallv
  (memory/VA translation; unrelated to CC) — **needs its own JIRA**.

---

## 1. Problem statement
RCCL `alltoallv`, RCN disabled (CC-only), GT multiplane (8 NICs/node, 4×100G, 8 paths/QP, ~62 QPs/NIC).
RCN on → completes (~23 GB/s). RCN off → **hard hang** (~50%), GPUs pinned, wire idle, MSN frozen.
Original root-cause writeup: `../alltoallv-rcnoff-hang-20260720-104445/HANDOFF.md`.

---

## 2. Root cause (confirmed with Build-1 instrumentation)

**Path state taxonomy:** each path is *active* (in `path_bitmap`), *disabled* (TX removed it when
window-exhausted; `path_removed_tx != path_removed_rx`), or *inactive* (in `inactive_path_bitmap`,
recoverable by bootstrap). Bootstrap derives `num_active_path = max_paths − num_inactive_path`, so
**disabled paths count as "active."**

**Two defects (both needed for the deadlock):**
1. **qwnd → 0:** RCN-off removes the per-path cwnd floor; MD drives per-path cwnd to 0. MD at the
   QP level is correctly floored at `qwnd_min` (rx_s2:439/523), but the **`force_inactivate`
   path-removal subtract `qp_cwnd_whole -= path_cwnd` (rx_s2:604) is unfloored** → qwnd crosses to 0.
   *Measured:* `num_cnt_qwnd_uf_forceinact = 1` (single crossing), `_fold = 0`, MD crossed floor 0×.
2. **Disabled-path stranding (§5.5):** a disabled path that drains (`snd_nxt==snd_una`) with `cwnd<=0`
   can't re-enable (rx_s3:267 needs `cwnd>0`) and — pre-fix — isn't demoted to inactive (the demotion
   existed only in the *settled* branch). It **strands**, inflating `num_active_path`.
   *Measured:* `num_cnt_disabled_drained_cwnd0 = 1313` on the wedged QP.

**Why it deadlocks:** bootstrap (tx_s2) needs (a) `num_active_path==0` or (b) `((num_active+1)<<aws) <
qp_cwnd`. Worked example (baseline wedge, GT-1 qp25): `num_active=8−3=5`, qwnd=0 → (a) `5==0` false,
(b) `96<0` false → no bootstrap → `path_bitmap=0` → nothing schedulable → hang.

---

## 3. The fix

### Fix A (recommended, ship this) — `rx/meta_roce_rx_s3.p4`
Add the missing `else if` in the disabled-path branch to demote a drained `cwnd<=0` disabled path to
inactive so bootstrap can recover it:
```p4
} else if ((d.snd_nxt == d.snd_una) && (d.cwnd_retry == 0) &&
           (p.force_inactivate == 0) && ((int<16>)d.cwnd <= 0)) {
    d.path_removed_rx = d.path_removed_tx;
    pred.update_path_bmp = 1;
    p.add_inactive_path = 1;
    p.flags.upd_inactive_path_bmp = 1;
}
```
Effect: `num_inactive` rises → `num_active_path` drops to 0 → bootstrap trigger (a) fires → paths
recovered. In practice this keeps qwnd from ever collapsing (**`forceinact=0` across all validation runs**).

### Fix B (in PR #118783, but NOT needed) — `tx/meta_roce_tx_s2.p4`
Adds `qp_cwnd == 0 ||` to `_bootstrap_needed` (re-arm bootstrap on total window collapse). **Redundant
with Fix A:** since Fix A prevents qwnd from reaching 0, Fix B's condition never triggers (0 firings in
30+ runs). Dropping it = one clean rx_s3 change. (Fix B alone also worked in isolation — 4/4 — but that's
moot if Fix A ships.)

---

## 4. Build-1 instrumentation (measurement counters)
4 counters added to SQCB4, set via rx PHV flags, incremented in rx_s7, exposed via a private nicctl:

| Counter | nicctl label | meaning |
|---|---|---|
| `num_cnt_qwnd_uf_forceinact` | QWND underflow (force_inactivate) | qwnd `<qwnd_min` right after the force_inactivate subtract |
| `num_cnt_qwnd_uf_fold` | QWND underflow (fold) | qwnd `<qwnd_min` after a tx/rx fold |
| `num_cnt_qwnd_uf_other` | QWND underflow (other) | qwnd `<qwnd_min` at end of rx_s2 (carryover/aftermath) |
| `num_cnt_disabled_drained_cwnd0` | Disabled+drained cwnd<=0 (stranded) | the §5.5 stranding predicate = **Fix A trigger** (counts demotions when Fix A is present) |

Read on a QP with the **private** nicctl:
```
sudo /root/pradeept/nicctl.bin show rdma queue-pair --raw --queue-pair-id <QP> --lif <LIF> \
   | grep -E 'num_cnt_qwnd_uf_|num_cnt_disabled_drained_cwnd0'
```

---

## 5. Artifacts

| Item | Location / value |
|---|---|
| Workspace / branch | `/ws/pradeept/ws/usr/src/github.com/pensando/sw-2`, branch `build1-instr-a4` (base `da4d25d29db` = tag `1.130.2-a-4`) |
| Build container | `pradeept_2026-07-22_07.14.00` (`/sw` = sw-2) |
| **FW (Fix A + instrumentation)** | `sw-2/ainic_fw_vulcano.tar`, md5 `672591484d5b2fee61876fade6f90971`; stamps `1.130.2-a-4-dirty` |
| **Private nicctl** (reads counters) | deployed `/root/pradeept/nicctl.bin` on both GT nodes, md5 `4271b6af7a0420732e0e99e8cf208d27` (~43M) |
| Patch — Build-1 only | `debug/build1-instrumentation/build1-instrumentation.patch` (applies on tag 1.130.2-a-4) |
| Patch — Build-1 + Fix A | `debug/build1-instrumentation/build1-instr-plus-fixA.patch` (current tree) |
| **busBW comparison report (all sizes)** | http://sw-dev9.pensando.io:8973/ (served from `debug/sanity-sack/report/index.html`) |

Build commands (in container, cwd `/sw`): FW = `make -f Makefile.build build-rudra-vulcano-hydra-ainic-fw`;
nicctl (cwd `/sw/nic`) = `make PIPELINE=rudra ASIC=vulcano P4_PROGRAM=hydra PLATFORM=hw ARCH=x86_64 nicctl.bin`.
⚠️ All variants stamp `1.130.2-a-4-dirty` — indistinguishable by version; track by md5.

---

## 6. Test methodology
Per run: **`nicctl clear pipeline internal state`** (both nodes) → run RCCL (`run.py --runs 1 --output <name>`)
→ verify. Verification signals:
- **Concluded** (no hang) — MSN frozen + not concluded = hang.
- **No stranded paths (authoritative):** `nicctl show rdma queue-pair path --raw` per-path predicate
  `path_removed_tx!=rx & snd_nxt==snd_una & cwnd<=0 & cwnd_retry==0 & force_inactivate==0` → count = 0.
  (Cheap fleet screen: `num_disabled_path==0` via `... queue-pair --rccl-data -j`.)
- **Stress present:** `disabled_drained_cwnd0 > 0` (demotions fired) — else the run didn't exercise it.
- **No qwnd wedge:** 0 QPs with `qp_cwnd_whole==0 & MSN frozen`; `forceinact` behavior.
- **Flag (separate bug):** `qp_err_dis_va_no_page`.

Reusable scripts: `/tmp/{soak_driver,msweep_driver}.sh`, `/tmp/parse_bw.py`, `/tmp/gen_report.py`.

---

## 7. Validation results (all on Fix-A image, RCN-off unless noted)

| Experiment | Result |
|---|---|
| Baseline a-4 (no fix) — negative control | alltoallv RCN-off hangs **~50%** (qwnd=0 wedge: forceinact=1, other=58, disabled_drained=1313) |
| Fix B only (ablation) | 4/4 clean |
| Fix A only — quick validate | 4/4 clean |
| Fix A "run-4 hang" (earlier) | **RESOLVED**: was the separate `va_no_page` error-disable, not a CC/Fix-A failure (see §8) |
| **16G × 1000-iter soak ×10** | **10/10 clean** — heavy stranding stress (demotions 3K–17K/QP), 0 stranded, 0 cc-wedge, forceinact=0; mid-run `path --raw`: 8–11 disabled paths live, 0 stranded |
| **Msg-sweep (16B→16G) n=100 ×20** | **20/20 clean** (statistical on realistic workload; light congestion so demotions ≈ 0) |
| **5-collective sanity, RCN on & off** (all_reduce, alltoall, alltoallv, reduce_scatter, all_gather; n=20) | all complete both modes, no hang; RCN-on ≈ RCN-off busBW |
| **SACK immediate vs window-delay** × RCN on/off (5-collective, n=20) | all 4 conditions complete, no hang; SACK mode makes ~no difference at this (loss-free) workload |

**Aggregate:** **30/30 clean** stress runs + all sanity conditions clean, vs ~50% baseline hang →
false-pass ≈ 1e-6; plus mechanistic proof (disabled paths occur live but never stranded).

### Peak out-of-place busBW (GB/s) — 5-collective sanity (per-size detail in the HTML report)
| collective | imm/RCNon | imm/RCNoff | delay/RCNon | delay/RCNoff |
|---|---|---|---|---|
| all_reduce | 351.0 | 351.1 | 350.9 | 351.8 |
| alltoall | 83.2 | 84.3 | 82.6 | 84.4 |
| alltoallv | 56.1 | 52.6 | 55.9 | 53.0 |
| reduce_scatter | 360.0 | 362.4 | 359.9 | 362.6 |
| all_gather | 351.3 | 353.1 | 351.3 | 352.8 |

Raw per-size data: `debug/sanity-sack/{immediate,window-delay}/` (temp_*_iteration_1.txt + xlsx + .out).

---

## 8. Separate issue — `va_no_page` error-disable (NOT the CC fix)
During long alltoallv RCN-off, some QPs (GT-1) get error-disabled with `qp_err_dis_va_no_page=1`
(`state=0x2`, `qp_cwnd_whole` healthy, `forceinact=0`, paths mid-`force_inactivate`). This is a VA→PA
"no page" memory-translation failure, **independent of CC** (would hang any FW). Correlates with
ACS-disabled bridges + shared GPU/NIC IOMMU groups. Vishwas's handoff §6
(`/home/vishwas/alltoallv-rcnoff-cwnd-collapse-fix-HANDOFF.md`) has details. **Action: file a separate JIRA.**
Distinguish from the CC hang: CC = `state=RTS(0x4)`, qwnd=0, paths cwnd=0; va_no_page = `state=0x2`,
qwnd healthy, `qp_err_dis_va_no_page=1`.

---

## 9. Testbed reference & gotchas
- GT-1 `10.30.69.101` (SC-GT-Node1, launcher) / GT-4 `10.30.69.98` (peer). SSH `root`/`docker`, password
  auth. BMC: GT-1 `10.30.69.88`, GT-4 `10.30.69.97` (BMC login `root`/`0penBmc`). **GT-4 BMC network is
  currently unreachable** (BMC chip alive via host KCS; `powerutil`/lanplus won't reach it — use
  `ipmitool` over KCS from the host, and never `power off` GT-4).
- SW stack (GT): RCCL **2.27.7** (`/home/amd/vul-rccl/rccl`), ROCm **7.0.2**, amd-anp **v1.3.0**
  (`/home/amd/vul-rccl/amd-anp-mp-new`, `librccl-anp.so`), rccl-tests `/home/amd/vul-rccl/rccl-tests`.
  Selected by `RCCL_RELEASE` (defaults 7.0.2 in `setup_env.sh:25`).
- Bringup: `/home/amd/vul-rccl-benchmark/setup.sh` (per-node multiplane bringup + rename + qos + vip routes).
- **Power-cycle gotcha:** after a host power cycle, GT-1 came up with QP `header_template_port_bitmap=0x0`
  (QPs can't TX → alltoallv stuck at msn=1, num_pkts=0 — NOT a CC hang). `setup.sh` re-run did NOT fix;
  **`nicctl reset card --all` + full `setup.sh` did**. Always verify `header_template_port_bitmap=0xf`
  on a fresh run after a reboot.
- FW persists across host reboot; bringup config + RCN state + `/tmp` files do not.

---

## 10. Useful nicctl commands (learned this effort)
- Clear counters/state: `nicctl clear pipeline internal state`
- RCN: `nicctl update pipeline rdma congestion-control profile -p <0-7> --rcn <enable|disable>`
- **SACK mode:** `nicctl update pipeline rdma path -p <0-7> --sack-retx-mode <immediate|window-delay|disable>`
  (per-profile; new QPs pick it up; verify via `sqcb0.sack_retx_mode` — 0x0=immediate, 0x1=window-delay)
- **Per-path CB state (stranded check):** `nicctl show rdma queue-pair path --raw --queue-pair-id <N> --lif <LIF>`
  → `pathcb2.{path_removed_tx,path_removed_rx,cwnd,cwnd_retry,snd_nxt,snd_una,force_inactivate}`
- Path taxonomy: `nicctl show rdma queue-pair --bdf <bdf> --rccl-data -j` → `num_active_path/num_disabled_path/num_inactive_path`

---

## 11. Open items / next steps
1. **Ship Fix A only** (rx_s3 demotion); drop Fix B from PR #118783 (data shows it's redundant).
2. **gtest/DOL** that forces the stranded precondition and asserts recovery — deterministic/CI (still open on Vishwas's checklist).
3. **File separate JIRA** for the `va_no_page` error-disable (§8).
4. Recover **GT-4 BMC** network (or lab-side check of its mgmt NIC / rack switch port).
5. Optional: SACK immediate-vs-delay under a **lossy/heavy** profile (16G×1000) to actually stress the mode difference (sanity showed no delta at n=20).

---

## 12. Artifact index
- `debug/build1-instrumentation/` — patches (`build1-instrumentation.patch`, `build1-instr-plus-fixA.patch`),
  `ALLTOALLV-RCNOFF-FIX-HANDOFF.md` (build), this file.
- `debug/build1-run-20260722-082342/` — `RESULTS.md` (baseline wedge + counters), `FIX-ABLATION.md`,
  `gt1-qp25-primary/`, `fixA-residual-hang/`, soak logs.
- `debug/sanity-sack/{immediate,window-delay}/` — per-size RCCL outputs (4 conditions) + xlsx.
- `debug/sanity-sack/report/index.html` — hosted busBW comparison (http://sw-dev9.pensando.io:8973/).
- `debug/alltoallv-rcnoff-hang-20260720-104445/` — original root-cause HANDOFF/RUNBOOK + pollers.
- Vishwas's fix handoff: `/home/vishwas/alltoallv-rcnoff-cwnd-collapse-fix-HANDOFF.md`.
