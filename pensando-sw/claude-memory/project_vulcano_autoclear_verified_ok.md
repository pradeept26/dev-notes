---
name: Always-on auto-clear verified fine on Vulcano (TXS-for-hydra parked)
description: Vulcano keeps scheduler auto-clear always ON and it is verified not a perf/fairness problem; the pulsar TXS port to hydra is therefore parked
type: project
originSessionId: 5c1791ad-e9cb-4ac7-ad27-4732167068b9
---
Always-on scheduler **auto-clear is verified NOT to be a problem on Vulcano**
(empirically confirmed by the team, 2026-07-13) — no fairness or perf pain at
scale or with RCCL, unlike the ~61% inter-queue asymmetry pulsar saw that
motivated pulsar's `txs_cmd`.

**Why:** Vulcano hydra intentionally keeps auto-clear ON for all QPs at all
scales (the scale-based auto-clear-disable is Salina-only). Testing confirmed
this is fine on Vulcano.

**How to apply:** The proposed port of pulsar's TXS (`txs_cmd`) fast-path into
the hydra pipeline is **PARKED / not pursuing** — its entire value was to
compensate for *disabling* auto-clear, which Vulcano has no need to do. Do not
implement TXS-for-hydra without a fresh, different motivation (e.g. a future
requirement to run auto-clear OFF on Vulcano). Study/design is captured in
`~/dev-notes/pensando-sw/reference/HYDRA-TXS-DESIGN.md` (open questions O1/O2/O3
already resolved there if it's ever revived) and `PULSAR-TXS-BEHAVIOR.md`.

**Path scheduler checked too (also parked):** hydra's schedulable path queues
(ACK/retx/cwnd/timer rings on path_cb0 — no pulsar equivalent) have a real
spurious-scheduling inefficiency in the **auto-clear-OFF** branch: the
"unused paths scheduler bit set" fix (commit da193a2f734, #101030) throttles
re-eval with `if (__random_number()[4:0]==0)`. txs_cmd would cleanly replace that
hack, BUT it only occurs auto-clear-OFF, which is Salina-only, and txs_cmd is
Vulcano-only — so the inefficiency's habitat can't use txs and Vulcano (txs
capable) never hits it (auto-clear ON). Net: no path ring needs txs today.
If Vulcano ever runs path queues auto-clear-OFF, ACK ring (cosA) is the
highest-value target and there cosA≠cosB so per-ring cos matters (see design doc
section 6b).

**Key safety constraint (design doc 6b.3):** TXS must NOT be applied to the
cwnd-retry ring (or any ring whose stop rides a `set_cindex`/`set_pindex`). Its
stop is `_path_cwnd_retry_process` (S3) doing `set_cindex + sched_eval`, which
advances ci AND is the mechanism that closes the producer(S7 set_pindex+eval)/
consumer race. A bare txs disable flips the scheduler off without the
reconciling eval → lost-wakeup/QP stall. Only the already-drained S0 empty-ring
stops (s0:318 ACK, s0:347 cosB, both `no_upd+eval`) are TXS-safe. The whole
scheme relies on the invariant "every pi-advance is paired with sched_eval."
