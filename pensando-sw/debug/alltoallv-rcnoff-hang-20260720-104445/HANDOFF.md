# Handoff: RCCL alltoallv Hang with RCN Disabled — Meta RoCE Path/Window Collapse

**Author:** Pradeep Thangaraju
**Date:** 2026-07-20
**Firmware:** 1.130.2-a-4 (Vulcano / Hydra / Meta RoCE)
**Severity:** High — hard hang of RCCL `alltoallv` when RCN is disabled; one wedged QP deadlocks the entire collective.
**Status:** Root-caused (code-level). Fix proposed, not yet implemented. Wedged setup captured; reproduction runbook prepared.

---

## 1. Executive Summary (TL;DR)

RCCL `alltoallv` **hangs** (not merely "10x slow") on the GT Vulcano multiplane testbed when **RCN is disabled** (CC-only). It runs fine with RCN enabled.

The hang is a **congestion-window collapse to zero** with no recovery:

- With RCN off, the per-path ECN/SACK multiplicative-decrease (MD) floor is **0** (`rx_s3.p4:173-175`). Under alltoallv's dense many-to-many traffic on a back-to-back link, the NIC generates internal CNPs (there is **zero packet loss, zero ECN marking, and PFC is off by design**), and MD drives every path's `cwnd` to 0.
- Per-path `cwnd → 0` ⇒ QP window `qwnd → 0` (qwnd is the sum of per-path windows; also drawn down by unfloored path-removal accounting at `rx_s2.p4:600`).
- Once `qwnd = 0` **and** all real active paths are gone, the QP can neither send nor bootstrap a replacement path, and the one outstanding message never completes. `ack_msn` freezes. Because `alltoallv` is an all-pairs synchronized collective, **one wedged QP blocks all 146 QPs/node** → the collective hangs; GPUs spin at 100%.
- **RCN masks the bug** entirely: `rcn_pwnd_min` keeps per-path `cwnd > 0`, so the window never collapses and the recovery paths stay armed.

**Primary root cause:** total window collapse (qwnd and per-path cwnd → 0) because there is no effective per-path window floor when RCN is off.
**Secondary/contributing:** a "disabled" (window-full) path drained at `cwnd=0` is never demoted to the inactive/bootstrappable set (`rx_s3.p4:258-273` has no `cwnd<=0` else-branch), which also keeps the bootstrap trigger from recovering.

---

## 2. Testbed

- Back-to-back 2-node, **no switch**. 8 Pensando Vulcano NICs/host, 4x100G profile (`meta-roce-4x100G-1`), 4 planes/NIC, path count 8.
- **GT-1** (SC-GT-Node1): 10.30.69.101, RCCL launcher, 8x MI300X
- **GT-4** (SC-GT-Node4): 10.30.69.98, peer, 8x MI325X
- SSH: `root` / `docker`, password auth. **Sequential SSH only** (parallel connections trigger auth failures).
- Scripts on nodes: `/home/amd/vul-rccl-benchmark`
- SW: FW 1.130.2-a-4, RCCL 2.27.7, ROCm 7.0.2, IB devices `roce_ai0_vip`..`roce_ai7_vip`.

---

## 3. Symptom / How It Manifests

- `alltoallv` with RCN disabled does not complete (observed wedged >16h; `temp_alltoallv_iteration_1.txt` stays 0 bytes). The **previous** collective (`alltoall`) completes normally — the hang is specific to `alltoallv` + RCN-off.
- GPUs pinned at 100%, but the **wire is idle**: measured ~38 packets/15s across all 8 NICs, **0 of 146 QPs advancing** their MSN over 30s. Fully frozen (not a slow crawl).
- Every QP shows `MSN = CSN + 1` (one message posted, never completes).

### Distinguishing hang from slow
```
# on GT-1: are any QPs progressing? (0 = hung)
sudo nicctl show rdma queue-pair --bdf 0000:03:00.0 --rccl-data --used -j   # sample twice, compare message_sequence_number
# wire throughput (near-zero = hung)
sudo nicctl show card statistics packet-buffer -j                            # sample UPLINK0 packets_out delta
```

---

## 4. How to Reproduce

See `RUNBOOK.md` (same directory) for exact commands. Outline:

1. Bringup both nodes (Guna's `setup.sh`), path count 8, identical CC profile.
2. **Baseline (RCN on):** `alltoallv`, 1 iter → completes ~7 min, ~23 GB/s.
3. **Repro (RCN off):** on both nodes `for p in 0..7; nicctl update pipeline rdma congestion-control profile -p $p --rcn disable`, then run `alltoallv` 1 iter → hangs. Repeat 2-3× for consistency.
4. Run `monitor_qp_collapse.sh` (this dir) on both nodes during the repro to capture the collapse curve (paths→disabled, cwnd→0, qwnd→0, MSN stall).

CC profile at repro (both nodes, all 8 NICs): Epsilon=1, Beta=1, Lambda=1, Omega=5, aws=4, qwnd_min=2, pwnd_min=2, min_rto=75, RCN disabled.

RCCL env of note: `NCCL_IB_QPS_PER_CONNECTION=1`, `NCCL_IB_TC=128`, `NCCL_IB_FIFO_TC=144`, `NCCL_NET_PLUGIN=librccl-anp.so`; ~62 QPs/NIC.

---

## 5. Root Cause (Code-Level)

### 5.1 Path states (taxonomy) — authoritative from nicctl `rdma_queue.cc:1711-1719`
```
active   = popcount(path_bitmap)                 # scheduled by TX
inactive = max_path - num_active_path            # in inactive_path_bitmap; recovered by bootstrap
disabled = max_path - active - inactive          # removed from active (window-full), still counted "active"
```
"**disabled**" is a NORMAL transient state: TX removes a path from `path_bitmap` when it has sent its window's worth (`tx_s3.p4:101-111`, `path_removed_tx = ~path_removed_rx`). RX re-adds it once outstanding drains (`rx_s3.p4:258-273` hysteresis).

### 5.2 The collapse (why qwnd → 0)
- ECN/SACK MD per-path floor is hardcoded **0** when RCN is off:
  `rx_s3.p4:173-175` → `min_pwnd = (rcn_multi_decr ? rcn_pwnd_min : 0)`.
- alltoallv on a back-to-back link ⇒ NIC-internal CNP generation (measured 85K-230K CNP/path; `num_ecn_received=0`, `num_drop=0` everywhere). MD hammers each path's `cwnd` to 0.
- `qwnd` (= sum of per-path windows) collapses to 0; also drawn down by **unfloored** structural writes: path-removal `qp_cwnd_whole -= path_cwnd` (`rx_s2.p4:600`) and the tx/rx fold (`rx_s2.p4:586/627`).
- `qwnd_min` does NOT save it: it floors only the QP-level MD decrement (`rx_s2.p4:439,523` early-return), is bypassed by the structural path-removal subtraction, and at 2 is far below the bootstrap threshold anyway (see 5.4).

### 5.3 Why bootstrap can't recover — both triggers are dead
`_bootstrap_needed` (`tx_s2.p4:90`, AIMD) fires if:
```
(a) num_active_path == 0
(b) ((num_active_path + 1) << avg_window_shift) < qp_cwnd
```
Live wedged values (GT-4 qp23): `num_active_path = max(8) - num_inactive(3) = 5`, `avg_window_shift = 4`, `qp_cwnd = 0`.
- (a) `5 == 0` → false — the 5 **disabled** paths are counted as active.
- (b) `(6 << 4) = 96 < 0` → false — qwnd collapsed to 0.

⇒ no bootstrap ⇒ `path_bitmap` stays 0 ⇒ `tx_s2.p4:322` drops every posted WQE ⇒ **permanent deadlock**. Confirmed frozen: `qp_cwnd_whole_tx`, `num_cnt_path_bootstrap`, `num_cnt_path_disabled`, `ack_msn` all unchanged over 30s.

### 5.4 The qwnd=0 linchpin
In healthy operation qwnd sits ~100-2048, so trigger (b) (`96 < qwnd`) keeps bootstrap repopulating active paths and the QP never hangs even while paths churn through the disabled state. **The hang requires qwnd to collapse all the way to 0** (well below the ~96 threshold), which removes the (b) escape. Note: a mere non-zero qwnd (e.g. qwnd_min=2) would NOT re-arm (b) — you need qwnd above `(num_active+1)<<aws`.

### 5.5 Secondary defect — disabled→inactive demotion gap
`rx_s3.p4:258-273` (disabled-path branch, `path_removed_tx != path_removed_rx`) re-enables to active **only `if (cwnd > 0)`** and has **no `else`**. The sibling branch for non-disabled paths (`rx_s3.p4:300-304`) correctly demotes a drained `cwnd<=0` path to `inactive_path_bitmap`. So a disabled path drained to `outstanding=0` with `cwnd=0` is stranded: not re-enabled, not demoted to inactive, still counted as active → inflates the phantom active count that defeats trigger (a).

### 5.6 Why RCN-off + alltoallv specific
- RCN on ⇒ `rcn_pwnd_min` floors per-path cwnd > 0 ⇒ qwnd never collapses, (b) stays armed, disabled paths always re-enable. Bug invisible.
- alltoallv's dense all-pairs traffic supplies the internal-CNP storm that collapses cwnd; other collectives (e.g. `alltoall`) are less dense and complete.

---

## 6. Live Evidence (wedged QP: GT-4 qp23, requester)

- lif `02000070-0100-0000-4242-0490818f1e40`, bdf 0000:03:00.0, qp 23
- `Queue state: RTS (rollback, spec_cindex=202, restart_ci=202)`
- `Active/Disabled/Inactive/Max = 0/5/3/8`; `path_bitmap=0`, `inactive_path_bitmap=0x19` (local paths 0,3,4); disabled = local paths 1,2,5,6,7
- `qp_cwnd_whole=0`, `qp_cwnd_fraction=0x38`, `qp_cwnd_whole_tx == qp_cwnd_whole_rx = 0x1db0`
- `MSN=56523 / BMSN=56524 / CSN=56522` (1 outstanding); firmware anomaly `[SQ 0023] ack_msn not advancing`
- Per-path: all 8 `cwnd=0`, all `snd_una==snd_nxt` (drained); path 7 has `snd_inflate=2`, `fsn_bitmap_3=0x6` (SACK residue)
- Buffer stats fleet-wide: `ingress_buffer_drop=0`, `ingress_buffer_byte_drop=0` (no loss); per-path `num_ecn_received=0`

Peer (GT-4's flow terminates at GT-1 qp23): GT-1 send side healthy (`4/0/4`, cwnd=15); GT-1 responder for the reverse flow at `Expected CSN=56522`, waiting on the message GT-4 cannot send.

Full dumps: `gt4-qp23/` and `gt1-qp23-peer/` in this directory.

---

## 7. Corrections to Prior Analysis (Guna's initial handoff)

The initial handoff (Slack doc F0BJ9BUTK6F) attributed it to "CC window collapse + PFC storm / lossy drops." Corrected by live data:

- **"27 billion PFC triggers"** = `port_monitor`, a cumulative **packet count** through P4EG0 IQ3 (equals `ingress_buffer_count`), **not** PFC pause events. PFC is disabled by design for Meta RoCE; zero pause frames.
- **"lossy → packet drops → RTO"** — `ingress_buffer_drop = 0` on all NICs; per-path `num_drop = 0`. **No loss.**
- **"38K-559K CWND retry retransmissions"** = `num_congestion_window_retry_retransmitted_packet` == `num_retry_ring_doorbell` (window-starved re-arm), **not** loss-driven retransmits.
- The problem is **not a 10x slowdown**; it is a hard hang (0 forward progress).

The correct enabling condition (RCN-off removes the per-path floor) and the collapse mechanism are as in §5.

---

## 8. Proposed Fix

**Preferred (addresses the primary root cause):** give per-path `cwnd` a floor of **1** for ECN/SACK MD when RCN is off — `rx_s3.p4:174`, change `min_pwnd` from 0 to 1 in the non-RCN branch. Keeps qwnd ≥ number of paths, so bootstrap trigger (b) stays armed and disabled paths always re-enable; eliminates both failure modes at the source.
- *Caveat:* this changes the "shed a path all the way to 0 under congestion" design intent (`docs/06-debugging.md` line ~835 notes ECN MD has no per-path floor by design). If path-shedding-to-zero must be preserved, use the alternative below instead of/with this.

**Alternative / hardening (preserve 0-shed, fix recovery):** add the missing `else` to the disabled-path branch at `rx_s3.p4:258-273` — when a disabled path is drained (`snd_nxt == snd_una`) with `cwnd <= 0` (and `!force_inactivate`, `!cwnd_retry`), demote it to `inactive_path_bitmap` (`add_inactive_path`, `upd_inactive_path_bmp`, sync `path_removed_rx = path_removed_tx`), mirroring the sibling at `rx_s3.p4:300-304`. This makes trigger (a) recover the QP (`num_inactive` rises → `num_active` drops to 0 → bootstrap fires) even with qwnd=0.

Recommend implementing **both** (floor prevents the collapse; demotion is belt-and-suspenders and restores the active/inactive invariant `_bootstrap_needed` relies on).

Note: `_bootstrap_needed`'s `num_active_path = max_paths - num_inactive_path` is correct **by design** (disabled paths are expected to return) — it is not itself a defect; it only misfires because the disabled paths get permanently stranded.

All changes are P4+ in the Hydra pipeline — must comply with `nic/p4/docs/p4-coding-rules.md` and be validated with gtest + DOL + a hardware repro.

---

## 9. Workaround

- **Keep RCN enabled** for alltoallv at this QP density (effectively required; masks the bug and gives ~23 GB/s).
- A wedged QP does **not** self-recover (no ACKs arriving) and is **not** the mandatory-destroy state (`fatal_err_retx_full=0`). Recover via QP reset (RST→RTS) or `nicctl reset card --all` + re-bringup.
- CC tuning (min_rto↑, qwnd-min↑, epsilon↑) may reduce the collapse rate but does not fix the deadlock.

---

## 10. Artifacts & Data Locations

Local (this machine): `/home/pradeept/dev-notes/pensando-sw/debug/alltoallv-rcnoff-hang-20260720-104445/`
- `README.md` — quick state + root-cause summary
- `HANDOFF.md` — this document
- `RUNBOOK.md` — clean-state reproduction steps (non-executed)
- `monitor_qp_collapse.sh` — read-only collapse monitor
- `gt4-qp23/` — wedged requester full dump (status/raw/detail/json, path status/raw/stats)
- `gt1-qp23-peer/` — peer/responder full dump

On GT-1 (original run outputs, may be overwritten by repro):
- `/home/amd/vul-rccl-benchmark/1.130.2-a-4_3iter_cc/` (stuck run), `..._3iter_rcn/`, `..._alltoallv_1iter_{rcn,cc}/`

Source (workspace `sw-2`): `nic/rudra/src/hydra/p4/p4plus-16/meta_roce/`
- `rx/meta_roce_rx_s3.p4` (per-path MD floor, re-enable/demotion), `rx/meta_roce_rx_s2.p4` (QP MD, qwnd_min, folds, path-removal)
- `tx/meta_roce_tx_s2.p4` (`_bootstrap_needed`, SQ spec/bootstrap gate), `tx/meta_roce_tx_s3.p4` (window-full disable)
- `docs/06-debugging.md` (path-state taxonomy, anomaly tree)

---

## 11. Open Questions / Next Steps

1. Implement the fix (floor + demotion) and validate: gtest, DOL, and hardware repro on GT (alltoallv RCN-off should complete or at least not hang).
2. Run the clean-state reproduction (RUNBOOK) 2-3× to confirm determinism and capture the collapse curve with the monitor.
3. Decide policy on ECN path-shedding-to-zero (floor of 1 vs demotion-only) with the CC owners.
4. File JIRA with this document + captured artifacts.
5. Separately: the CC-only congestion collapse (all paths cwnd→0 under internal CNP) is a distinct performance topic even after the hang is fixed — alltoallv at this QP density likely still needs RCN for good throughput.
