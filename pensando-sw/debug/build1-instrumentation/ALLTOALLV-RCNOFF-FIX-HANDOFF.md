# Handoff — alltoallv RCN-off QP-window-collapse hang: instrumentation, root cause, and fix ablation

**Author:** Pradeep Thangaraju (via Claude)
**Date:** 2026-07-22
**Platform:** Vulcano / Hydra / Meta RoCE, base FW **1.130.2-a-4** (commit `da4d25d29db`)
**Testbed:** GT 2-node back-to-back, RCN disabled
**Related PR (the fix under study):** #118783 `vishwas/alltoallv-rcnoff-cwnd-collapse-fix`

---

## 0. TL;DR

- RCCL **alltoallv with RCN disabled HANGS** on GT Vulcano (~50% of sweeps). One QP's congestion
  window (`qp_cwnd_whole`, "qwnd") collapses to 0 and cannot recover → the whole collective wedges.
- We built a **measurement FW ("Build-1")** on clean a-4 that adds 4 SQCB4 counters + a private
  `nicctl` to read them, and used it to pin the mechanism on real hardware.
- **Root cause (counter- + code-confirmed):** qwnd crosses the `qwnd_min` floor via the **unfloored
  `force_inactivate` path-removal subtract** (`rx_s2.p4:604`). MD (multiplicative decrease) is
  correctly floored and only walks qwnd *down to* the floor. Separately, drained "disabled" paths
  with `cwnd<=0` are **stranded** (never demoted to inactive), which defeats the bootstrap recovery.
- PR #118783 bundles **two** fixes: **Fix A** (rx_s3 demote stranded path → inactive) and **Fix B**
  (tx_s2 add `qp_cwnd == 0` to the bootstrap trigger). We ablated them:
  - **Fix B only → 4/4 clean sweeps, no hang.** (Load-bearing.)
  - **Fix A only → 3 clean, then a hang on run 4 — but INCONCLUSIVE:** the hung QP also carried a
    `qp_err_dis_va_no_page=1` + spec-rollback signature, so that hang may be an unrelated memory
    error rather than a Fix-A path-mechanic failure.

---

## 1. Problem statement

RCCL `alltoallv`, RCN disabled (CC-only), GT Vulcano multiplane (8 NICs/node, 4x100G, 8 paths/QP).
- With RCN **on**: completes (~23 GB/s). With RCN **off**: hard hang (~50% of sweeps), GPUs pinned,
  wire idle, one wedged QP blocks the all-pairs collective.
- Full original root-cause writeup: `../alltoallv-rcnoff-hang-20260720-104445/HANDOFF.md`.

---

## 2. The instrumentation (Build-1)

Four `bit<32>` counters added to **SQCB4** (requester RX stats), set via rx PHV flags and incremented
in rx_s7, exposed through a private `nicctl`:

| Counter (SQCB4) | nicctl label / JSON key | Meaning |
|---|---|---|
| `num_cnt_qwnd_uf_forceinact` | "QWND underflow (force_inactivate)" / `num_qwnd_uf_forceinact` | qwnd went `< qwnd_min` right after the `force_inactivate` subtract (rx_s2:604) |
| `num_cnt_qwnd_uf_fold` | "QWND underflow (fold)" / `num_qwnd_uf_fold` | qwnd `< qwnd_min` after a tx/rx fold (rx_s2:586/636) |
| `num_cnt_qwnd_uf_other` | "QWND underflow (other)" / `num_qwnd_uf_other` | qwnd `< qwnd_min` at end of rx_s2 from any other/carryover source |
| `num_cnt_disabled_drained_cwnd0` | "Disabled+drained cwnd<=0 (stranded)" / `num_disabled_drained_cwnd0` | a disabled path drained with `cwnd<=0` (the §5.5 stranding condition = Fix A trigger) |

Read on a QP with the **private** nicctl (installed nicctl will not show these):
```
sudo /tmp/nicctl.bin show rdma queue-pair --raw --queue-pair-id <QP> --lif <LIF> \
   | grep -E 'num_cnt_qwnd_uf_|num_cnt_disabled_drained_cwnd0'
sudo /tmp/nicctl.bin show rdma queue-pair statistics --queue-pair-id <QP> --lif <LIF> \
   | grep -E 'QWND underflow|Disabled\+drained'
```

---

## 3. THE DIFF (details)

Two patch files in this directory:
- `build1-instrumentation.patch` — Build-1 counters only, applies on tag **1.130.2-a-4**. 6 files, +73/-2.
- `build1-instr-plus-fixA.patch` — **current tree** = Build-1 counters **+ Fix A** (demotion). 6 files, +79/-2.

Workspace: `/ws/pradeept/ws/usr/src/github.com/pensando/sw-2`, branch `build1-instr-a4` (detached-style
branch off `da4d25d29db`). All paths below are under
`nic/rudra/src/hydra/p4/p4plus-16/meta_roce/` unless noted.

### 3a. Build-1 instrumentation hunks

**`include/rdma_sqcb.p4`** — 4 counters into `rdma_sqcb4_t`; shrink `__pad_to_64B` 176→48 (CB stays 512b):
```p4
    bit<16>     num_cnt_skip_path_inactivate;
+   bit<32>     num_cnt_qwnd_uf_forceinact;
+   bit<32>     num_cnt_qwnd_uf_fold;
+   bit<32>     num_cnt_qwnd_uf_other;
+   bit<32>     num_cnt_disabled_drained_cwnd0;
-   bit<176>    __pad_to_64B;
+   bit<48>     __pad_to_64B;
```

**`rx/meta_roce_rx_phv.p4`** — 4 flags into `meta_roce_rx_global_flags_t`; `__unused_flags` 10→6:
```p4
+   bit<1>  qwnd_uf_forceinact;
+   bit<1>  qwnd_uf_fold;
+   bit<1>  qwnd_uf_other;
+   bit<1>  disabled_drained_cwnd0;
-   bit<10> __unused_flags;
+   bit<6>  __unused_flags;
```

**`rx/meta_roce_rx_s2.p4`** — set flags at the two folds, at the force_inactivate subtract, and a
catch-all at the end of `req_rx_ack_process`. NOTE the cast `(int<16>)(bit<16>)p.qwnd_min`
(`qwnd_min` is `bit<8>`; a direct `bit<8>→int<16>` cast is rejected by the compiler):
```p4
  // after each fold (2 sites, rx_s2:586 and :636):
  if (__unlikely((int<16>)d.qp_cwnd_whole < (int<16>)(bit<16>)p.qwnd_min)) { p.flags.qwnd_uf_fold = 1; }
  // after the force_inactivate subtract (rx_s2:604):
  d.qp_cwnd_whole = d.qp_cwnd_whole - p.path_cwnd;
  if (__unlikely((int<16>)d.qp_cwnd_whole < (int<16>)(bit<16>)p.qwnd_min)) { p.flags.qwnd_uf_forceinact = 1; }
  // catch-all at end of the action:
  if (__unlikely((int<16>)d.qp_cwnd_whole < (int<16>)(bit<16>)p.qwnd_min &&
                 p.flags.qwnd_uf_fold == 0 && p.flags.qwnd_uf_forceinact == 0)) { p.flags.qwnd_uf_other = 1; }
```

**`rx/meta_roce_rx_s7.p4`** — increment the 4 counters, gated on the flags (in `req_rx_stats_process`):
```p4
  if (__unlikely(p.flags.qwnd_uf_forceinact == 1))     d.num_cnt_qwnd_uf_forceinact = d.num_cnt_qwnd_uf_forceinact + 1;
  if (__unlikely(p.flags.qwnd_uf_fold == 1))           d.num_cnt_qwnd_uf_fold       = d.num_cnt_qwnd_uf_fold + 1;
  if (__unlikely(p.flags.qwnd_uf_other == 1))          d.num_cnt_qwnd_uf_other      = d.num_cnt_qwnd_uf_other + 1;
  if (__unlikely(p.flags.disabled_drained_cwnd0 == 1)) d.num_cnt_disabled_drained_cwnd0 = d.num_cnt_disabled_drained_cwnd0 + 1;
```

**`nic/infra/ainic/nicctl/pipeline/hydra/rdma_queue.cc`** — 4 fields into `req_rx_cc_stats_t`, plus
CB-read mapping in `fill_sq_stats`, JSON put in `generate_sq_stats_json_output`, and text lines in
`print_sq_stats` (the FILL_STATS labels listed in §2).

### 3b. Fix A hunk (CURRENT tree, `rx/meta_roce_rx_s3.p4`)

In the disabled-path branch (`path_removed_tx != path_removed_rx`), after the re-enable `if (cwnd>0…)`,
add the demotion for a drained `cwnd<=0` disabled path. Merged with the Build-1 counter so the counter
now tallies demotions performed:
```p4
  } else if (__unlikely((d.snd_nxt == d.snd_una) && ((int<16>)d.cwnd <= 0) &&
                        (p.force_inactivate == 0) && (d.cwnd_retry == 0))) {
      p.flags.disabled_drained_cwnd0 = 1;         // Build-1 counter (= demotions taken)
      d.path_removed_rx = d.path_removed_tx;       // Fix A: demote stranded path to inactive
      pred.update_path_bmp = 1;
      p.add_inactive_path = 1;
      p.flags.upd_inactive_path_bmp = 1;
  }
```
(PR #118783's Fix A is the same actions without the counter line.)

### 3c. Fix B hunk (NOT in current tree — documented; it is the load-bearing fix)

`tx/meta_roce_tx_s2.p4`, inside `_bootstrap_needed`, add `qp_cwnd == 0 ||` to the AIMD trigger:
```p4
   (d.congestion_state == QP_CNGST_STATE_AIMD &&
    (num_active_path == 0 ||
+    qp_cwnd == 0 ||
     (((bit<16>)(num_active_path + 1) << d.avg_window_shift) < qp_cwnd)))
```
To build a Fix-B image: revert the rx_s3 Fix-A hunk (keep the counter-only `else if`) and add this line.

---

## 4. Build, artifacts, flash

### Container / build
- Docker container: **`pradeept_2026-07-22_07.14.00`**, `/sw` = `sw-2` (git-describe resolves; sw-2 is
  the main worktree so no DOCKER_RUN_ARGS workaround needed).
- FW build (regenerates `p4_generated_types.h` + flashable tar), cwd `/sw`:
  ```
  make -f Makefile.build build-rudra-vulcano-hydra-ainic-fw     # → /sw/ainic_fw_vulcano.tar
  ```
- nicctl build (AFTER the FW/P4 build — depends on regenerated types), cwd `/sw/nic`:
  ```
  make PIPELINE=rudra ASIC=vulcano P4_PROGRAM=hydra PLATFORM=hw ARCH=x86_64 nicctl.bin
  # → /sw/nic/build/x86_64/hw/rudra/vulcano/out/nicctl_bin/nicctl.bin (~43M)
  ```

### Artifacts (as of this handoff)
- **FW tar (Build-1 + Fix A):** `/ws/pradeept/ws/usr/src/github.com/pensando/sw-2/ainic_fw_vulcano.tar`
  — 10,629,120 bytes, md5 **`672591484d5b2fee61876fade6f90971`**. FW version stamps
  **`1.130.2-a-4-dirty`** (the `-dirty` = uncommitted patch; useful "instrumented image active" marker).
- **Private nicctl:** deployed on both GT nodes at **`/tmp/nicctl.bin`** — 44,903,872 bytes,
  md5 **`4271b6af7a0420732e0e99e8cf208d27`** (Build-1 build; CB layout is identical across Fix A/B so
  it reads the counters on any of the images). NOTE: not currently in the host build tree — rebuild
  with the command above if you need a fresh copy.
- ⚠️ **All three images (Build-1, +Fix A, +Fix B) stamp `1.130.2-a-4-dirty` — indistinguishable by
  version string. Track which tar you flash by md5.**

### Flash (parallel — works; the old `err 255` was a stale-workspace build artifact, not secure-boot)
```
SSHP="sshpass -p docker ssh -o StrictHostKeyChecking=no -o PubkeyAuthentication=no -o PreferredAuthentications=password -o NumberOfPasswordPrompts=1"
SCPP="sshpass -p docker scp -o StrictHostKeyChecking=no -o PubkeyAuthentication=no -o PreferredAuthentications=password -o NumberOfPasswordPrompts=1"
for n in 10.30.69.101 10.30.69.98; do $SCPP <tar> root@$n:/tmp/fw.tar; done
$SSHP root@10.30.69.101 "cd /tmp && sudo nicctl update firmware -i fw.tar" >/tmp/f1.log 2>&1 &
$SSHP root@10.30.69.98  "cd /tmp && sudo nicctl update firmware -i fw.tar" >/tmp/f4.log 2>&1 & wait   # expect 8 "Successful" each
$SSHP root@10.30.69.101 "sudo nicctl reset card --all" & $SSHP root@10.30.69.98 "sudo nicctl reset card --all" & wait
for n in 10.30.69.101 10.30.69.98; do $SSHP root@$n "cd /home/amd/vul-rccl-benchmark && bash setup.sh" & done; wait
for n in 10.30.69.101 10.30.69.98; do $SSHP root@$n "for p in 0 1 2 3 4 5 6 7; do sudo nicctl update pipeline rdma congestion-control profile -p \$p --rcn disable; done"; done
for n in 10.30.69.101 10.30.69.98; do $SCPP <nicctl.bin> root@$n:/tmp/nicctl.bin; $SSHP root@$n "chmod +x /tmp/nicctl.bin"; done
```

---

## 5. Test procedure

1. Confirm both nodes: 8 cards, 8 `roce_ai*_vip`, RCN **Disabled**, `qwnd_min=2`.
2. `setup_env.sh` on GT-1 filtered to **alltoallv only** (already is).
3. Launch a sweep from GT-1:
   `cd /home/amd/vul-rccl-benchmark && nohup timeout 1800 python3 run.py --runs 1 --output <name> &`
4. A clean sweep concludes in ~3-4 min ("Collective test concluded"). A HANG = MSN frozen, run never
   concludes, GPUs pinned.
5. Find the wedged QP (enumerate `show rdma queue-pair --bdf <bdf> --rccl-data -j` across all 8 BDFs;
   look for `qp_cwnd_whole==0 && msn>csn && msn>1`, and/or `num_inactive_path`/`num_disabled_path`
   anomalies), then read the counters (§2).
   - ⚠️ A cwnd==0 filter alone is NOT sufficient — the Fix-A residual hang has `cwnd>0` (see §6).
     Better: also sample MSN twice ~10s apart; frozen MSN with `msn>csn` = wedged.

Reusable sweep driver used here: `/tmp/fixB_driver.sh` / `/tmp/fixA_driver.sh` (loops N sweeps,
records pass/hang + `num_inactive_path` histogram; note its wedge detector only caught `cwnd==0`).

---

## 6. Root cause (confirmed) + fix analysis

### 6a. Why qwnd → 0 (the collapse) — the numbers, from the baseline wedge (qp25)
At the wedge: `qp_cwnd_whole=0`, `qwnd_min=2`, `path_bitmap=0` (active 0), `inactive=3`, `disabled=5`,
`avg_window_shift=4`. Counters: **`forceinact=1`, `fold=0`, `other=58`, `disabled_drained=1313`**;
`CC multiplicative decrements=102,546`.
- MD ran 100k+ times but crossed the floor **0** times → MD is correctly floored (`rx_s2.p4:439,523`
  `return` if the result would go `< qwnd_min`). It only walks qwnd down to the floor.
- The single floor crossing is the **unfloored `force_inactivate` subtract** `qp_cwnd_whole -= path_cwnd`
  (`rx_s2.p4:604`) → `forceinact=1`. (Committed value is exactly 0, so at the crossing `path_cwnd==qwnd`.)
- `other=58` is **aftermath, not cause**: the catch-all at rx_s2:644 runs *before* this packet's MD and
  fires whenever an ACK enters with qwnd already `<qwnd_min` and does no fold — i.e., post-collapse ACKs
  observing the already-0 qwnd (`qp_cwnd_whole_tx==qp_cwnd_whole_rx` so the fold never reconciles it back).

### 6b. Why bootstrap can't recover (the deadlock) — §5.5 stranding
`num_active_path = max_paths - num_inactive_path` (tx_s2:128) — so **disabled paths count as "active."**
A disabled path (`path_removed_tx != path_removed_rx`) that drains (`snd_nxt==snd_una`) with `cwnd<=0`
has no exit pre-Fix-A: can't re-enable (needs `cwnd>0`, rx_s3:267) and isn't demoted to inactive (that
demotion lived only in the *settled* branch rx_s3:309-314). It **strands**, inflating `num_active_path`.
- Bootstrap (`tx_s2:130`): (a) `num_active_path==0` and (b) `((num_active+1)<<aws) < qp_cwnd`.
- Worked example (qp25): `num_active_path = 8-3 = 5`. (a) `5==0` → false (5 stranded paths masquerade
  as active). (b) `(6<<4)=96 < 0` → false. → no bootstrap → deadlock.

### 6c. The two fixes (PR #118783)
- **Fix A** (rx_s3 demotion): demote drained `cwnd<=0` disabled paths → inactive, so `num_active_path`
  can reach 0 and bootstrap trigger (a) fires.
- **Fix B** (tx_s2 `qp_cwnd==0 ||`): re-arm bootstrap directly when qwnd collapsed, regardless of the
  (inflated) active count. Bootstrap then pulls from `inactive_path_bitmap` (gate reduces to
  `num_inactive_path > num_down`).

### 6d. Ablation results on GT (this effort)
| Build | alltoallv RCN-off | Notes |
|---|---|---|
| baseline a-4 (Build-1 only) | HANG ~50% (runs 2,4 of 4) | qwnd=0 wedge; counters as §6a |
| **Fix B only** | **4/4 clean, no hang** | qwnd collapses then bootstrap re-arms via qwnd==0; `num_inactive` stays healthy |
| **Fix A only** | 3 clean, then hang on run 4 | **INCONCLUSIVE** — see §6e |

### 6e. Fix-A run-4 hang — inconclusive (important caveat)
The run-4 bottleneck QP (gt1 qp2067, lif …dd40) shows a path-deadlock signature (all 8 paths disabled,
`num_inactive_path=0`, `qp_cwnd_whole=206` healthy, `num_cnt_path_bootstrap` frozen — bootstrap gate
`num_inactive>num_down` fails; Fix A's `cwnd<=0` demotion doesn't apply to these `cwnd>0` disabled
paths). **BUT** the same QP also has `qp_err_dis_va_no_page=1`, `spec_failure=1`, `restart_msn<msn`
(spec rollback), `state=0x2` (non-RTS) — a VA2PA error-disable / rollback that was ABSENT on the clean
qwnd=0 wedge. So run-4 could be (a) a Fix-A path deadlock or (b) an unrelated va2pa error-disable that
would hang any build. **Not resolved.** Full detail: `../build1-run-20260722-082342/FIX-ABLATION.md`.

---

## 7. Testbed reference
- GT-1 `10.30.69.101` (SC-GT-Node1, RCCL launcher); GT-4 `10.30.69.98` (SC-GT-Node4, peer).
  SSH `root`/`docker`, **password auth**. BMC: gt1 `10.30.69.88`, gt4 `10.30.69.97`.
- 8 Vulcano NICs/node, 4x100G, 8 paths/QP, ~62 QPs/NIC; scripts in `/home/amd/vul-rccl-benchmark`.
- Gotcha: `nicctl reset card --all` + `setup.sh` on an ALREADY-wedged setup rebooted GT-4 once
  (recovered on its own; FW persists across host reboot, but bringup config + RCN-disable + /tmp files
  do not — redo those after a reboot).

---

## 8. Open items / next steps
1. **Disambiguate the Fix-A run-4 hang (§6e):** re-run Fix-A, catch another hang, capture
   `show rdma queue-pair` **status** (err-disabled?), **path statistics** (path_cb per-path state),
   and full raw; and check whether `qp_err_dis_va_no_page` ever appears on Fix-B/baseline runs.
2. **Confirm the full PR (A+B)** is immune to the all-disabled/`cwnd>0`/`num_inactive=0` state (neither
   hunk directly addresses it — Fix B's `qp_cwnd==0` wouldn't fire at `qwnd=206`).
3. Longer soak of Fix-B to bound the residual hang probability.

---

## 9. Artifact index
- This dir (`debug/build1-instrumentation/`): `build1-instrumentation.patch` (Build-1 on a-4),
  `build1-instr-plus-fixA.patch` (Build-1 + Fix A, current tree), `base-commit.txt`,
  `BUILD1-INSTRUMENTATION-HANDOFF.md` (original build-from handoff), this file.
- `debug/build1-run-20260722-082342/`: `RESULTS.md` (baseline wedge + counters + full qstate analysis),
  `FIX-ABLATION.md` (Fix A vs B), `gt1-qp25-primary/` (baseline wedge dumps),
  `fixA-residual-hang/gt1_qp2067_dd40_raw.txt` (Fix-A run-4 QP).
- `debug/alltoallv-rcnoff-hang-20260720-104445/`: original root-cause HANDOFF/RUNBOOK + pollers.
