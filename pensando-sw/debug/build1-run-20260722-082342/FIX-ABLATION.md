# Fix ablation — which mechanism fixes the alltoallv RCN-off hang?

PR #118783 bundles TWO changes:
- **Fix A** (rx_s3): demote a drained disabled path with `cwnd<=0` to inactive (`add_inactive_path`).
- **Fix B** (tx_s2): add `qp_cwnd == 0 ||` to `_bootstrap_needed` so bootstrap re-arms when qwnd collapses.

Ablation on GT (a-4 baseline + Build-1 instrumentation, alltoallv RCN-off, ~50% baseline hang rate).

## Fix B only (tx_s2 one-liner; rx_s3 unchanged)
**Result: 4/4 clean sweeps, NO hang.** During recovery the qwnd collapses to 0 and bootstrap
re-arms via the `qp_cwnd==0` clause, pulling from the inactive pool (which had paths available).
`num_inactive_path` histograms stayed healthy. → **Fix B eliminates the hang.**

## Fix A only (rx_s3 demotion; tx_s2 reverted)
**Result: 3 clean, then HUNG on run 4.** Mechanism observed:
- Demotions fire heavily (`disabled_drained_cwnd0` = 2000–4000 on active QPs) and the qwnd does
  NOT collapse (`forceinact=0`, `cwnd>0` throughout) — Fix A prevents the qwnd=0 mode.
- BUT a DIFFERENT terminal deadlock appears. Captured bottleneck QP (GT-1 qp2067, lif …dd40):
  - `msn=56776 / csn=56775` (1 outstanding, **frozen** >20s)
  - `qp_cwnd_whole = 206` (**healthy, not collapsed**)
  - `path_bitmap = 0` (0 active), `inactive_path_bitmap = 0`, `num_inactive_path = 0`
    → **all 8 paths disabled, zero inactive**
  - `num_cnt_path_bootstrap = 882` **frozen** (bootstrap not firing)
- Why unrecoverable: bootstrap's inner gate `(num_active_path + num_down) < max_paths` reduces to
  `num_inactive_path > num_down`; with `num_inactive=0` it is false → **bootstrap gated off**. And
  Fix A's demotion only triggers for `cwnd<=0` disabled paths — these are disabled with `cwnd>0`,
  so they are never demoted → never become inactive → bootstrap never gets a path to pull.

## Verdict (REVISED after reading the full raw dump — earlier verdict was over-confident)
- **Fix B only: 4/4 clean, no hang** — solid signal it eliminates the qwnd=0 hang.
- **Fix A only: 3 clean, then a hang on run 4 — but attribution is NOT clean.** The bottleneck QP
  (gt1 qp2067) is in an all-paths-disabled / `cwnd>0` / zero-inactive state (consistent with a
  bootstrap-gate deadlock) **but ALSO shows `qp_err_dis_va_no_page=1`, `spec_failure=1`, and an
  active speculative rollback (`restart_msn`<`msn`), with `state=0x2` (non-RTS).** That is a VA2PA
  "no page" error-disable / spec-rollback condition, which was NOT present on the clean qwnd=0 wedge
  (qp25 had all `qp_err_dis_*`=0).

Two competing explanations for the run-4 hang, undistinguished by this single dump:
  (a) Fix-A path/bootstrap deadlock (all-disabled/cwnd>0/0-inactive), with va_no_page a downstream
      symptom of rollback retransmits; or
  (b) an INDEPENDENT va2pa error-disable that could hang any build (baseline/Fix B included) and is
      unrelated to Fix A's path mechanics.

**Therefore: "Fix A alone is insufficient" is NOT established.** Fix B is clearly effective (4/4);
Fix A's single hang may be an unrelated memory/spec error.

## To resolve (need a re-run with full capture)
Re-run Fix-A, catch another hang, and capture per wedged QP:
- `show rdma queue-pair` **status** (is it error-disabled / ERR state?)
- **path statistics** (path_cb: per-path snd_nxt/snd_una/cwnd/path_removed_tx-rx — are all 8 truly
  disabled+drained with cwnd>0, or stuck with outstanding?)
- full **raw** (recheck qp_err_dis_va_no_page, spec_failure, restart_*)
Also: run Fix-B (or baseline) longer and check whether `qp_err_dis_va_no_page` ever appears — if it
does independent of the fix, run-4 was likely explanation (b).

## Open flag for the PR author (Vishwas)
The residual deadlock (all paths disabled, `cwnd>0`, `num_inactive=0`) is not *directly* addressed by
either hunk — Fix B's `qp_cwnd==0` clause also wouldn't fire here (`qwnd=206≠0`). Fix B avoided it in
4/4 runs (it steers recovery through the qwnd=0 + inactive-pool path), but it's worth confirming the
FULL PR (A+B) is immune, or considering hardening the bootstrap inner-gate / demoting `cwnd>0`
disabled paths that have drained.

Artifacts: `fixA-residual-hang/gt1_qp2067_dd40_raw.txt`; Fix-B sweep log `/tmp/fixB_sweeps.log`.
