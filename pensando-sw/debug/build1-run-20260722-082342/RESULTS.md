# Build-1 instrumentation results — alltoallv RCN-off qwnd→0 (GT, 2026-07-22)

**FW:** `1.130.2-a-4-dirty` (Build-1 instrumentation, flashed on both GT nodes, all 16 NICs).
**Setup:** GT-1 10.30.69.101 / GT-4 10.30.69.98, 8 Vulcano NICs/node, 4x100G, RCN **disabled**,
qwnd_min=2. Private nicctl `/tmp/nicctl.bin` used to read the new SQCB4 counters.

## Repro (intermittent ~50%)
- Run 1 (`build1_cc`): **completed** (~3 min).
- Run 2 (`build1_cc_2`): **HUNG** — primary QP GT-1 qp25, lif …dd40 (msn=64715, disabled=5, active=0, cwnd=0).
- Run 3 (`build1_cc_3`): **completed** (~3 min).
- Run 4 (`build1_cc_4`): **HUNG** — primary QP GT-1 qp21, lif …dd40 (msn=60618, disabled=7, active=0, cwnd=0).
- Both hangs: MSN frozen, run never concluded, GPUs pinned; freeze-checked (counters+msn unchanged after 30s = deadlock).
- Note: the wedge landed on **GT-1** both times (prior session was GT-4); same lif …dd40. GT-4 rebooted
  once during a reset+re-bringup on an already-wedged setup (recovered on its own; FW persisted).

## Determinism of the counter signature (two independent hangs)
| Counter | Run 2 (qp25) | Run 4 (qp21) |
|---|---|---|
| num_cnt_qwnd_uf_forceinact | 1 | 1 |
| num_cnt_qwnd_uf_fold | 0 | 0 |
| num_cnt_qwnd_uf_other | 58 | 31 |
| num_cnt_disabled_drained_cwnd0 | 1313 | 1352 |

**Signature is deterministic:** `forceinact`=1 exactly, `fold`=0, `other`=tens (dominant qwnd-underflow
driver), `disabled_drained_cwnd0`≈1300 (large, consistent).

## Counters (primary wedged QP GT-1 qp25 vs a still-churning healthy QP2065, same lif)
| Counter | Wedged qp25 (cwnd=0) | Healthy qp2065 (cwnd=145) |
|---|---|---|
| num_cnt_qwnd_uf_forceinact | 1 | 0 |
| num_cnt_qwnd_uf_fold | 0 | 0 |
| num_cnt_qwnd_uf_other | **58** | 0 |
| num_cnt_disabled_drained_cwnd0 | **1313** | 504 |

## Interpretation (CONFIRMS HANDOFF §5.2 — corrected after code review of rx_s2.p4)
**IMPORTANT correction:** an earlier draft here read `qwnd_uf_other` as an independent "MD-driven"
cause. Code review of `req_rx_ack_process` (meta_roce_rx_s2.p4) shows that is wrong — `other` is an
*aftermath* observation, not a cause. See the mechanism below.

Catch-all placement / floor facts:
- `qwnd_uf_other` is checked at **rx_s2:644**, which runs *before* this packet's MD/AI (MD at 667, AI
  at 684). MD (`_multiplicative_decrease`) and the rate-hint path are **floored**: they `return`
  without writing if the result would cross below `qwnd_min` (lines **439**, **523**). So MD walks
  qwnd *down to* qwnd_min but can never cross it.
- Before line 644 the only *unfloored decreases* are the **fold** (586/636, flags `qwnd_uf_fold`) and
  the **force_inactivate** path-removal subtract `qp_cwnd_whole -= path_cwnd` (**604**, flags
  `qwnd_uf_forceinact`, then `return`s at 618 — never reaching 644). Giveback/AI only increase.
- Hence a sub-floor `qp_cwnd_whole` can only be *written* by fold or force_inactivate. With `fold=0`,
  the observed `qp_cwnd_whole=0` was written by **force_inactivate**.

Conclusions:
1. **qwnd crosses the floor via the unfloored force_inactivate subtract (rx_s2:604)** — `forceinact=1`
   is that single crossing. This **confirms HANDOFF §5.2's primary suspicion**. MD is correctly
   floored and is not the crosser.
2. **`qwnd_uf_other` (31–58) = carryover:** post-collapse ACKs that enter rx_s2 with qwnd already 0
   and do no fold this packet → tick `other` at line 644. It is the aftermath, not the driver.
   (Healthy QP: `other=0`, qwnd=145 — never sub-floor.)
3. **disabled+drained+cwnd<=0 stranding is heavy but transient:** 1313 on the wedged QP, **504 even on
   a healthy QP** — fires constantly, normally recovered once cwnd>0; terminal only after qwnd
   collapses. → the disabled→inactive demotion (rx_s3:258-273 `else`) is belt-and-suspenders; the
   primary fix is to **stop qwnd crossing to 0** (floor the force_inactivate subtract at qwnd_min
   and/or the per-path cwnd floor rx_s3:174 so qwnd never approaches the floor).

## Evidence from saved qstate (GT-1 qp25 → remote qp27, lif …dd40, bdf 0000:03:00.0)
Flow: 2001::50:1:0:30 → 2001::50:2:4:30 (GT-1→GT-4), DSCP 32, WRITE workload, state RTS/RTS,
**no error-disable** (all `qp_err_dis_*`=0 → pure window/path deadlock, not a fatal-err QP).

**Collapsed window (the wedge):**
- `qp_cwnd_whole = 0` (committed), `qp_cwnd_fraction = 49`
- `qp_cwnd_whole_tx = qp_cwnd_whole_rx = 5568 (0x15c0)` — tx==rx, so the rx_s2 fold never fires
  (explains `fold=0` AND why qwnd can't self-heal: the fold reconciles tx↔rx, but they already match
  while the committed whole sits at 0). This is the concrete reason each later ACK ticks `other`.
- `qp_cwnd_max = 2048`, `qwnd_min = 2`, `rcn_pwnd_min = 2`, `rcn = 0` (OFF), `exact_cwnd_enforce = 1`,
  `congestion_state = 2` (AIMD), `avg_window_shift = 4`, `log_pwnd_max = 8`, `epsilon=1`, `omega=5`.

**Path taxonomy (deadlock, matches HANDOFF §5.3 exactly):**
- `path_bitmap = 0` → **0 active**; `inactive_path_bitmap = 0xa4` (paths 2,5,7), `num_inactive_path = 3`;
  → **disabled = 8 − 0 − 3 = 5** (paths 0,1,3,4,6). `max_paths=8`, `num_ports=4`.
- `bootstrap_in_progress=0`, `force_bootstrap=0` → no recovery armed.
- Bootstrap triggers with live values: `num_active_path = max(8) − inactive(3) = 5`.
  (a) `5==0` → **false** (5 disabled paths counted as active); (b) `(5+1)<<4 = 96 < qwnd(0)` → **false**.
  Both dead → permanent deadlock.

**Sequence numbers (1 outstanding, frozen):** `msn = 64715`, `csn = 64714` → MSN = CSN+1 (one message
posted, never completes); `ack_msn` frozen; RTS rollback (`restart_ci == spec_sq_cindex`).

**Force_inactivate arithmetic:** committed `qp_cwnd_whole = 0` is *exact* (not a bit<16> wrap to ~65530),
so at the single crossing `path_cwnd == qp_cwnd_whole` and the subtract landed on 0 (`0 < qwnd_min 2`
→ `forceinact=1`). ⇒ a floor that clamps the force_inactivate subtract at `qwnd_min` would leave qwnd=2,
which still fails bootstrap trigger (b) (needs qwnd>96) — so per HANDOFF §5.4 the per-path floor +
demotion are needed, not just clamping this one subtract.

**Why MD didn't cross (confirms floor works):** `CC multiplicative decrements = 102,546` QP-level
(and ~12k/path) yet `forceinact=1`, `fold=0` → MD ran 100k+ times, floored at qwnd_min every time,
never crossed. `CC additive increments = 97,045`. `num_cnt_path_disabled = 3,318,582`,
`path_bootstrap = 1392`, `path_inactive ≈ 1391` → paths churned through disabled millions of times and
bootstrap recovered them ~1392 times before the terminal wedge.

**Congestion is internal-CNP, zero loss/ECN (confirms §5.6):** across all 8 paths **ECN received = 0**,
**Drops = 0**, but **CNP received ≈ 735k total** (per-path 22k–194k). Retransmits are window-starvation,
not loss: per path `CWND retry retransmit == Retry ring doorbells` (e.g. path5 346,706==346,706);
RTO/SACK retx are small (~1–6k). RTT is blown out by queuing: the **>75µs bucket dominates every path**
(min 9µs, max 573–736µs).

## Artifacts (this dir)
- `gt1-qp25-primary/` — status/raw/statistics/path_stats of the primary wedged QP
- `PRIMARY_wedge_counters.txt`, `contrast_qp2065_counters.txt`
- `sampler_gt4.log`, `monitor_gt1.log`, `monitor_gt4.log`, `postflash_versions.txt`, `sanity.txt`
