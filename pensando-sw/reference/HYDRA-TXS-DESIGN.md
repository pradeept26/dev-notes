# TXS fast-path for the Hydra (Meta-RoCE) TX pipeline — Design

Proposal to port the pulsar `txs_cmd` transmit-scheduler fast-path (see
`PULSAR-TXS-BEHAVIOR.md`) into the hydra Meta-RoCE TX pipeline
(`nic/rudra/src/hydra/p4/p4plus-16/meta_roce/`).

> **STATUS: PARKED / NOT PURSUING (2026-07-13).** The gating question (C2) is
> answered **negative**: **always-on auto-clear has been verified NOT to be a
> problem on Vulcano** (empirically confirmed — no fairness/perf pain at scale
> or RCCL). Since TXS's entire value in pulsar was to *compensate for disabling
> auto-clear*, and Vulcano has no need to disable it, TXS provides no benefit in
> the current hydra regime. (With auto-clear ON there aren't even spurious
> end-of-SQ PHVs to eliminate — S0 re-arms via the eval doorbell.) This document
> is retained as **reference** in case a future need to run auto-clear OFF on
> Vulcano arises (e.g. a new scheduling requirement); if so, the design below is
> ready and its open questions O1/O2/O3 are already resolved. Do not implement
> without a fresh motivation.

Status: **design / study only — parked (see banner).** Not implemented.

## 1. Problem & motivation

Hydra currently controls the SQ scheduler exclusively via the **classic
doorbell + auto-clear** scheme:

- `meta_roce_tx_util.h:40-46` defines only `_sq_sched_disable()` /
  `_sq_sched_eval()` (classic `__ring_doorbell`). There is **no `txs_cmd`,
  no `stopped_txs`** anywhere in hydra.
- S0 `req_tx_sqcb_process` (`tx/meta_roce_tx_s0.p4:130-155`) re-arms the
  scheduler with `_ring_eval_doorbell(SQ)` only **if auto-clear is enabled**;
  when the SQ looks empty it drops the PHV.
- The committed-state stop happens later in **S2** `_sq_doorbell(exp_cindex)`
  (`tx/meta_roce_tx_s2.p4:74-84`), which issues `doorbell_set_cindex` when
  `exp_cindex == pindex` (queue empty) or on a 16-boundary.

Auto-clear has the **same fairness problem** pulsar hit (unfair scheduling once
more than one queue is active). The two ASICs handle it differently **today**:

- **Salina:** dynamically **disables** auto-clear at high scale — ≥64 active
  qstates **or** any RCCL QP. This machinery is **`#if defined(SALINA)` only**
  (`admincmd_handler.c:291-376` scale-config block; `:980-990` RCCL trigger;
  all threshold-crossing call sites Salina-gated).
- **Vulcano:** auto-clear is **enabled at init and stays ON** for all QPs, all
  scales, including RCCL. There is no scale-based disable on Vulcano — see the
  explicit comment `admincmd_handler.c:991`
  ("Vulcano: No scaling - autoclear already enabled at init, stays enabled").
  Per-QP autoclear (SQ `:1056-1058`, RQ `:1134-1136`) is driven purely by CoS
  config, no longer gated on `is_rccl`.

So on Vulcano today we run the GPU/RCCL regime with **auto-clear ON** — the
"always-on" compromise proposed in `VULCANO-AUTOCLEAR-CHANGES-NEEDED.md`
(2026-02-25), which has since been implemented (that doc is now stale). This
avoids the extra end-of-SQ doorbell latency but keeps auto-clear's inherent
scheduling unfairness at scale.

**This is exactly the gap TXS closes.** `txs_cmd` is what let pulsar run
auto-clear **OFF** (fair) without a latency penalty — a cheap, fast end-of-SQ
stop. Porting it to hydra would let Vulcano turn auto-clear off at scale for
fairness, instead of being stuck with the current always-on compromise. With
auto-clear off and no TXS, hydra's S0 `if (auto_clear) _ring_eval_doorbell(...)`
guards (`tx/meta_roce_tx_s0.p4:146-152`) are skipped, so the scheduler leans on
S2's committed-state doorbell to stop — and between S0 speculating "empty" and
S2 committing, the scheduler keeps firing PHVs that fall through the S0
empty-drop branch (wasted MPU cycles). TXS removes that window.

## 2. Goal

On Vulcano, when auto-clear is OFF, let S0 **speculatively fast-disable** the
SQ scheduler the moment it believes it has launched the last PHV, and guarantee
a **race-free re-eval** once committed qstate is known — eliminating the
spurious end-of-SQ PHVs without a latency penalty and without unfairness.

Salina: unchanged (single AXI channel; `txs_cmd` is Vulcano-only).

## 3. Key architectural difference vs pulsar

| | Pulsar (`rdma_req_tx`) | Hydra (`meta_roce` tx) |
|---|---|---|
| Speculative stop | S0 `rdma_req_tx_s0_sqcb.p4:255-271` | **S0 `req_tx_sqcb_process`** |
| Committed qstate + doorbell | **S6** `write_back` (`eval_doorbell`) | **S2** `_sq_doorbell` (`tx/meta_roce_tx_s2.p4:74-84, 295-353`) |
| Carrier bit | `p.stopped_txs` (phv:554) | new `p.flags.stopped_txs` |
| Spec-fail catch | S5 `ki_spec_sq_emptied` → resync | S1/S2 `last_spec_failed` / `spec_failure!=spec_color` rollback |

**The race-free re-eval must live in S2 for hydra, not S6.** Hydra advances the
committed `exp_sq_cindex` and rings the SQ doorbell in S2; that is the natural
place to do "if we stopped_txs in S0, force a `doorbell_sched_eval` now."

## 4. Proposed changes

### 4.1 Primitive (P4)
Add a hydra `txs_cmd_doorbell()` + `_txs_cmd_doorbell(cos,set)`, mirroring
pulsar but living in hydra's tree
(`meta_roce/tx/meta_roce_tx_util.h`, or hydra's
`rdma/include/rdma_util.h`). The underlying extern `__SPRID_TXS_CMD` /
`__mtspr` is already available to hydra (`nic/tools/sorrento/p4include/mpu_externs.p4`).

Bake in the pulsar bug-fix lessons from day one (all three field sources are
now confirmed available in hydra — see section 6):
- **qid = `p.p4_intr_global.tm_q_depth`** (scheduler qid), NOT `qid`/QP id.
  Available: `bit<14> tm_q_depth` in `meta_roce/include/rdma_types.p4:1515`
  (also `common_headers.p4`). [O2 resolved]
- **lif = `LIF_ID_FOR_QTYPE(lif, qtype)`**, full 7-bit, instance = top bit.
  Hydra already uses `LIF_ID_FOR_QTYPE` in `_sq_ring_doorbell`
  (`meta_roce_tx_util.h:32`), so the helper is in hand.
- **cos = `d.cosB`** (SQCB0 embeds `ASIC_QSTATE_HEADER_COMMON` →
  `cosB`/`cosA`, `p4plus_common.p4:78`). On the **SQ, `cosA == cosB` always**
  for an active (RTS) QP — nicmgr sets both to the same value in QP-modify
  (`admincmd_handler.c:3117-3130`: `cos` for data QPs, `ack_cos` for CTS).
  So there is no cosA-vs-cosB ambiguity and the pulsar cos bug (`374e9b9e7df`)
  structurally cannot occur on the SQ. [O1 resolved]

Gate with a hydra `RDMA_USE_TXS_CMD` equivalent (`#ifndef SALINA` / per-ASIC)
plus a runtime table-constant kill-switch for bring-up.

### 4.2 PHV flag
Reuse the existing spare `bit<1> rsvd` in TE Flit 1 of the TX PHV
(`tx/meta_roce_tx_phv.p4:192`) — rename it to `stopped_txs`:
```p4
bit<1>   stopped_txs;   // was rsvd; set S0 (txs fast-stop), read S2 for re-eval
```
Rationale [O3 resolved]:
- **Zero PHV growth** — layout-neutral rename; the bit is already allocated in
  Flit 1's accounted 512b.
- **Genuinely unused** — no references to the bare `p.rsvd` in tx/ or rx/.
- **Live across S0→S2** — Flit 1 holds the fast-path scalars (spec_color,
  pindex, path_qid, …) that are set in S0/S1 and read through S2/S3.
- **No hazards** — it is a scalar working field, not in a header_union, not
  emitted to the wire, and not Tx/Rx-shared (that region is Flit 3).
- **No explicit clear needed** — P4+ PHV fields are zero by default, so, like
  pulsar, only ever set it to 1 in the stop case; every other path reads 0.

Do NOT add a bit to `meta_roce_tx_global_flags_t` — that word is already full
at exactly 32 bits.

### 4.3 S0 hook — speculative fast stop
In `req_tx_sqcb_process` (`tx/meta_roce_tx_s0.p4:134-155`), in the branch that
advances speculation, when the **next** speculative index would empty the ring
and no other SQ work is pending, and auto-clear is OFF:
```p4
#if RDMA_USE_TXS_CMD
if (!(bool)p.flags.sched_auto_clear &&
    next_spec_sq_cindex == d.pi_0 &&
    (__ring_not_empty() & (1 << RDMA_SQCB_SQ_RING_ID)) != 0) {
    p.stopped_txs = 1;                 // renamed rsvd bit; 0 by default elsewhere
    _txs_cmd_doorbell(d.cosB, false);  // fast-disable (cosA==cosB on SQ)
}
#endif
```
Keep the existing auto-clear path untouched (txs only kicks in when auto-clear
is off). No explicit `stopped_txs = 0` — PHV zero-default covers it.

### 4.4 S2 hook — race-free re-eval
In S2, wherever committed SQ state is advanced and `_sq_doorbell` is
considered (`tx/meta_roce_tx_s2.p4:295-353`), add:
```p4
#if RDMA_USE_TXS_CMD
if (p.stopped_txs == 1) {
    _sq_sched_eval();   // classic race-free eval; doorbell engine decides
    // (do NOT gate this on spec_initial_failure — pulsar hang 374e9b9e7df)
}
#endif
```
This must fire on **every** S2 exit path when `stopped_txs` is set, including
spec-fail (`_sq_spec_fail_initiate`), error/drop, and recovery — otherwise the
scheduler stays off forever (pulsar's fenced-WQE hang, `374e9b9e7df`).

### 4.5 nicmgr / config
Adopt the pulsar model for Vulcano: **auto-clear OFF + txs_cmd ON** for the
high-scale/RCCL data QPs, instead of the "always-on auto-clear" workaround in
`VULCANO-AUTOCLEAR-CHANGES-NEEDED.md`. Provide a table-constant/CB gate so it
can be toggled for bring-up. Salina keeps its current dynamic behavior.

## 5. Correctness invariants (carry over from pulsar)

1. Every S0 `txs_cmd(disable)` is paired with a guaranteed S2 re-eval.
2. Never gate the re-eval on a spec/rate sub-condition — if `stopped_txs`, always
   re-eval.
3. Feed txs_cmd the exact scheduler **qid (tm_q_depth)**, full 7-bit **lif**,
   and correct **cos**.
4. Model safety: on SIM the re-eval is mandatory or the model deadlocks; the
   `stopped_txs` bit is what distinguishes "must re-eval" from any "must stay
   disabled" case.

## 6. Open questions / risks

### Resolved (verified against code 2026-07-13)

- **O1 — cos sourcing: RESOLVED.** Use `d.cosB`. SQCB0 embeds
  `ASIC_QSTATE_HEADER_COMMON` (`rdma_sqcb.p4:26` → `cosB`/`cosA` in
  `p4plus_common.p4:78`). On the SQ, **`cosA == cosB` for any active (RTS) QP**:
  QP-modify sets both to `cos` (data) or `ack_cos` (CTS)
  (`admincmd_handler.c:3117-3130`), and the SQ can't schedule before RTS
  (`meta_roce_tx_s0.p4:117`). cosA/cosB only diverge on the **path CB** ACK-NAK
  ring via `cos_sel` (`admincmd_handler.c:741-744`), never on the SQ. → the
  pulsar cos bug (`374e9b9e7df`) cannot occur on the SQ path.
- **O2 — sched qid (`tm_q_depth`): RESOLVED.** Present as `bit<14> tm_q_depth`
  (`meta_roce/include/rdma_types.p4:1515`, `common_headers.p4`).
- **O3 — PHV slot: RESOLVED.** Reuse spare `rsvd` bit
  (`tx/meta_roce_tx_phv.p4:192`), layout-neutral rename, zero growth, live
  S0→S2, no wire/RX-alias hazard. The `meta_roce_tx_global_flags_t` word is full
  (32b) so do NOT add there. PHV zero-default means no explicit clear.

### Still open (design judgment / must-verify)

- **C1/O4 — S2 re-eval must cover ALL exit paths.** S2 has several exits
  (`_sq_doorbell`, `_sq_doorbell_if_autoclear`, `_sq_spec_fail_initiate`,
  error/drop) at `tx/meta_roce_tx_s2.p4:295-353`. Every one must do the
  `if (stopped_txs) _sq_sched_eval()` when the bit is set — a single missed
  path is the pulsar fenced-WQE hang (`374e9b9e7df`). **Open design choice:**
  scatter the guard across S2 exits, or place one guaranteed re-eval at a
  choke-point every PHV hits (e.g. S7 stats) — evaluate which is safer/cheaper.
- **C2 — is moving Vulcano off always-on auto-clear justified? ANSWERED: NO
  (verified 2026-07-13).** Always-on auto-clear has been empirically verified to
  NOT be a problem on Vulcano (no fairness/perf pain at scale or RCCL, unlike the
  pulsar 61% asymmetry). This removes TXS's motivation for hydra → design PARKED
  (see top banner). The remaining items below only matter if this decision is
  ever revisited.
- **C4/O7 — spec/rollback interaction.** Verify a mis-speculated "last" packet
  that nonetheless transmits still ends with a correct re-eval, given hydra's
  rollback model (`spec_failure != spec_color` in S0, `last_spec_failed` in
  S1/S2). Correctness must-verify, not a blocker (pulsar VSW-1112 / 374).
- **O5 — mcache / instruction budget.** Extra S0 branch + S2 re-eval on the SQ
  fast path; `__unlikely` the txs branch; check `nic/p4/docs/p4-coding-rules.md`
  and `docs/vulcano-mcache.md`.
- **C3/O6 — scope.** SQ-only for v1. path_tx rings analyzed separately in
  section 9 (also parked, same reason).

## 6b. Path scheduler (path_tx) analysis — hydra-unique, also parked

Hydra has schedulable **path queues** (no pulsar equivalent). `path_cb0` drives
four rings via the S0 `path_tx_s0_process` dispatcher
(`tx/meta_roce_tx_s0.p4:165-358`):

| Ring | CoS | Trigger | Continue | Stop-on-drain |
|------|-----|---------|----------|---------------|
| ACK-NAK | cosA (hi-pri) | `pi_ack!=ci_ack` | **unconditional** eval (`s0:197-203`) | eval if AC / **random-eval** if not (`s0:314-325`) |
| retx (SACK/RTO) | cosB | retx ring non-empty | eval if AC (`s0:241-249`) | shared cosB drain |
| CWND-retry | cosB | window reopens | eval if AC (`s0:271-279`) | shared cosB drain |
| timer (RTO) | cosB | `pi_timer!=ci_timer` | eval (`s0:284`) | shared cosB drain |
| *(cosB drain)* | cosB | ring empty | — | eval if AC / **random-eval** if not (`s0:343-353`) |

**Real inefficiency found:** commit `da193a2f734` ("fix for unused paths having
the scheduler bit set", #101030) added a probabilistic throttle — on drain with
**auto-clear OFF**, re-eval only `if (__random_number()[4:0] == 0)` (~1/32).
With AC off the scheduler bit persists on an idle path, so HW fires spurious
PHVs and it takes ~32 of them on average before a random eval clears the bit.
**This is textbook `txs_cmd` territory:** one deterministic 1-instruction SPR
disable on drain → zero spurious PHVs, and the `__random_number` hack goes away.

**Why it's still parked (structural dead-end):**
1. The random-eval hack runs **only in the auto-clear-OFF branch**. With
   auto-clear ON (Vulcano today), the drain eval finds the ring empty and stops
   cleanly — the "unused path scheduler bit" problem does not occur.
2. The auto-clear-OFF regime (where the hack lives, where txs would help) is
   **Salina-only** (high scale / RCCL).
3. `txs_cmd` is a **Vulcano-only** HW feature (unavailable on Salina).

→ The inefficiency's actual habitat (Salina, AC-off) can't use txs; the ASIC
that has txs (Vulcano) doesn't hit the inefficiency (AC-on). They never
intersect. **No path ring needs txs optimization under current ASIC/config.**

**If Vulcano ever runs path queues AC-off** (e.g. a future ACK-vs-data cosA/cosB
fairness need, or if the random-eval throttle is measured to delay ACK
delivery), ranking would be: **ACK ring (cosA) highest** (latency-sensitive; its
stop-on-drain uses the random hack), then the shared **cosB drain**
(retx/cwnd/timer). Note for that case: on the path CB cosA ≠ cosB and `cos_sel`
redirects the ACK ring (`admincmd_handler.c:741-744`), so the pulsar cos bug
(`374e9b9e7df`) **does** apply here — feed each ring its own cos, unlike the SQ.

### 6b.1 Eval happens LATE for the retry rings (not S0)

Unlike the SQ (stop@S0 / re-eval@S2) and the ACK ring (evals @S0), the
**retx and cwnd-retry rings make their continue/stop decision late in the
pipeline**, because it is window/FSN-dependent (only known after S3's
`_get_pwnd` / `outstanding_pkts` / `snd_nxt` vs `snd_max`):

- **ACK-NAK**: eval only in **S0** — continue = unconditional `no_upd+eval`
  (`s0:197-203`, rung early to pipeline the next ACK); drain @`s0:314-325`.
  Armed from the responder side in **RX S5** (`meta_roce_rx_s5.p4:39-45`,
  `set_pindex+eval`).
- **cwnd-retry**: real decision in **S3 `_path_cwnd_retry_process`**
  (`s3:171-285`) — done@`s3:194` (`set_cindex+eval`, random-throttled),
  complete@`s3:252` (`set_cindex+eval`, deterministic), continue@`s3:276`
  (`no_upd+eval` if AC); re-arm in **S7** (`s7:150-158`, `set_pindex+eval`).
- **retx-RTO**: RTO trigger/arm in **S3** (`s3:424-430`, `incr_pindex+enable`);
  drain via S0 color-check (`s0:214-223`).

### 6b.2 Doorbell-op limitation — TXS can't carry an index update

`txs_cmd` only flips the scheduler on/off. Most path-ring doorbells ride an
index update, which TXS cannot do:

| Site | Doorbell op | Needs ci/pi update? | TXS-safe? |
|------|-------------|---------------------|-----------|
| ACK continue `s0:197` | `no_upd + eval` | no (but it's *eval*, not disable) | no |
| ACK drain `s0:318` | `no_upd + eval` (random) | no — ring already empty | **no** (async producer, see 6b.3) |
| cosB drain `s0:347` | `no_upd + eval` (random) | no — cosB rings already empty | **no** (async producer, see 6b.3) |
| cwnd done `s3:194` | `set_cindex + eval` (random) | **yes — consumes retry reqs** | no |
| cwnd complete `s3:252` | `set_cindex + eval` | **yes** | no (already clean) |
| RTO trigger `s3:428` | `incr_pindex + enable` | yes | no |
| ACK arm (RX) `s5:42` | `set_pindex + eval` | yes | no |
| retry re-arm `s7:156` | `set_pindex + eval` | yes | no |

`set_cindex` here is not redundant: it **advances ci to the producer index,
marking the retry requests consumed**, and the paired `sched_eval` then stops
the now-empty ring.

Because every path ring also has an asynchronous producer (6b.3/6b.4), a bare
disable races the arm regardless of index update, so **there is no TXS-safe stop
point on the path** — including the two S0 empty-ring drains.

### 6b.3 Race analysis — why TXS is UNSAFE on the cwnd-retry ring

Producer/consumer on the cwnd-retry ring run from different stages/PHVs:
- **Producer** (normal TX PHV): `_window_check` (S3) closes the window →
  `snd_max=snd_nxt`, `cwnd_retry=1`, `retry_ring_db=1` (`s3:87-95`); then S7
  `num_retry_ring_db++` + **`set_pindex + sched_eval`** (`s7:151-158`).
- **Consumer** (cwnd-retry PHV): `_path_cwnd_retry_process` (S3) services
  `snd_nxt..snd_max`; on completion `cwnd_retry=0` + **`set_cindex+sched_eval`**
  (`s3:249-258`).

**Current design is race-free** for lost wakeups, resting on three invariants:
1. **Eval-always (ring level):** every pi-advance (`set_pindex`@S7) is *always*
   paired with `sched_eval`; `set_cindex`@S3 writes the conservative snapshot
   `p.pindex` (= `pi_cwnd_retry` read @S0, `s0:265`) ≤ current pi. Doorbells
   serialize per queue, so the last eval reconciles final ci/pi and re-arms
   whenever pi>ci. No pi ever advances without an eval → no lost wakeup.
2. **State coherence:** `cwnd_retry`/`snd_max`/`snd_nxt` (path_cb2) are RMW'd
   under the S3 table lock, serializing producer vs consumer.
3. **Producer counter:** `num_retry_ring_db` (path_tx_stats_t) is RMW'd under
   the S7 lock → monotonic, no lost increment.

Dangerous interleave self-corrects:
```
consumer S3: snd_nxt==snd_max → cwnd_retry=0, set_cindex(ci=5)+eval → ci==pi==5 → STOP
producer S3 (sees cwnd_retry=0): snd_max=snd_nxt, cwnd_retry=1, retry_ring_db=1
producer S7: num_retry_ring_db 5→6, set_pindex(6)+eval → ci=5 != pi=6 → SCHEDULED ✅
```

**Implication:** the `set_cindex + sched_eval` in `_path_cwnd_retry_process` is
not merely "an index update we can't replace" — it is the mechanism that
**closes** the producer/consumer race. A bare `txs_cmd(disable)` flips the
scheduler off *without* the reconciling eval and *without* advancing ci, so a
racing producer `set_pindex+eval` could be clobbered off with no following eval
→ genuine **lost wakeup / QP stall**. **TXS must not be applied to the
cwnd-retry ring** (and by the same logic, to any ring whose stop rides a
`set_cindex`/`set_pindex`).

Residual to verify on HW: that `set_pindex`'s pi-write and its paired
`sched_eval` are atomic within the doorbell engine (the whole argument hinges on
no pi-advance being observable without its eval) — see `docs/rdma/asic.md`
doorbell semantics.

### 6b.4 Summary — the path does NOT need TXS disable

**TXS is not needed and not safe for any path ring; path is dropped from TXS
scope. TXS is an SQ-only concept for hydra (and even that is parked).**

The path scheduler's existing **eval-on-drain is already the correct design**,
for three independent reasons:

1. **No benefit.** Vulcano runs auto-clear ON, so `sched_eval` on drain already
   stops each ring cleanly and deterministically. There is nothing to optimize.

2. **Unsafe by construction — every path ring has an asynchronous producer**
   (ACK ← RX S5 `set_pindex+eval`; cwnd-retry ← S7 `set_pindex+eval`; retx ← S3
   RTO `incr_pindex+enable`; timer ← HW). The safety of the whole scheme is the
   invariant *"every pi-advance is paired with a `sched_eval`."* Every stop must
   therefore be a **reconciling eval**, not a blind disable. `txs_cmd(disable)`
   carries no eval, so it races the producer's arm and can turn the scheduler
   off after work was posted, with no eval to follow → **lost wakeup / QP stall**:
   ```
   producer: set_pindex(pi 5→6) + eval   → armed (work pending)
   S0:       txs_disable                 → sched OFF, pi(6)≠ci(5), no eval → STALL
   ```
   This holds even for the already-drained S0 empty-ring stops: a producer can
   arm between the `pi==ci` check and the disable.

3. **No speculative gap to exploit (unlike the SQ).** The SQ's TXS works only as
   *fast-disable @S0 + mandatory reconciling eval @S2* — it just moves the stop
   earlier in the S0-speculate → S2-commit window while the eval still runs. The
   path rings decide stop **at** their eval point (S0 for ACK, S3 for cwnd), so
   there is no earlier point where a fast disable could buy latency ahead of a
   later eval.

## 7. Test plan

- **QEMU model** (`qemu-test` skill): primary deadlock catcher — a missing
  re-eval hangs the model. Run SQ drain / sporadic-post patterns.
- **DOL** `dol/rudra/test/rdma_hydra/` (`dol` skill): write/send/read, multi-WQE,
  single-FRPMR (pulsar AI-4730 case), fenced-WQE recovery (pulsar 374 hang case).
- **gtest** (`gtest` skill): S0/S2 unit behavior; end-of-SQ spec.
- **p4plus-unit-test**: per-stage insn/cycle deltas for S0 and S2.
- **HW perf** (`benchmark` skill): RCCL/high-scale bandwidth + fairness across
  many QPs with auto-clear OFF + txs ON vs the always-on-autoclear workaround —
  the 4-queue asymmetry pulsar measured is the metric to beat.

## 8. Rollout

1. Land primitive + PHV bit + S0/S2 hooks behind a default-off gate.
2. Bring up on QEMU model → DOL → HW.
3. Flip Vulcano config from "auto-clear always on" workaround to
   "auto-clear off + txs on" for high-scale/RCCL.
4. Update `docs/07-feature-status.md` (meta_roce) with the introducing PR.

---
**Created:** 2026-07-13
**Companion:** `PULSAR-TXS-BEHAVIOR.md`, `HYDRA-AUTOCLEAR-BEHAVIOR.md`,
`VULCANO-AUTOCLEAR-CHANGES-NEEDED.md`
**Source of truth:** read the hydra `meta_roce/tx/` code; this is a design note
and can drift.
