---
name: Always-on auto-clear verified fine on Vulcano (TXS-for-hydra parked)
description: Vulcano keeps scheduler auto-clear always ON and it is verified not a perf/fairness problem; the pulsar TXS port to hydra is therefore parked
type: project
originSessionId: 5c1791ad-e9cb-4ac7-ad27-4732167068b9
---
Always-on scheduler **auto-clear is verified NOT to be a problem on Vulcano**
(empirically confirmed by the team, 2026-07-13) — no fairness or meaningful perf
pain at scale or with RCCL, unlike the ~61% inter-queue asymmetry pulsar saw that
motivated pulsar's `txs_cmd`.

**Refinement (2026-07-21, A-B-C-A RCCL test on SMC 16-GPU):** there IS a *tiny*
real collective-throughput ordering **AC-off ≥ AC-off+txs ≥ AC-on** — i.e.
always-on auto-clear (the Vulcano default = B1) is actually the *slowest* of the
three, by up to ~1.2% on `alltoall` (negligible on `all_reduce`). Confirmed real,
not noise (B2 bracketed, drift <0.1%; bands separated on alltoall). Attributed to
auto-clear's much higher SQ scheduler doorbell churn (~230× under saturation).
Still far too small to change the "auto-clear-ON is fine / TXS-for-hydra parked"
call, but "no perf pain" is more precisely "≤~1.2%, collective-dependent." Data:
handoff Phase 4b + `txs-hw-validation/data/results_smc_rccl_aba/`.

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

**Path dropped from TXS scope entirely (design doc 6b.4):** txs disable is
neither needed nor safe for ANY path ring. (1) No benefit — Vulcano autoclear-ON
already stops path rings cleanly via eval-on-drain. (2) Unsafe by construction —
every path ring has an async producer (ACK←RX S5 set_pindex+eval; cwnd←S7
set_pindex+eval; retx←S3 RTO incr_pindex+enable; timer←HW), so every stop MUST
be a reconciling sched_eval, never a bare disable; a txs disable races the arm →
lost-wakeup/QP stall. This kills even the "already-drained" S0 empty-ring stops
(s0:318/s0:347). (3) No speculative gap like the SQ (which is fast-disable@S0 +
mandatory reconcile-eval@S2). The scheme relies on the invariant "every
pi-advance is paired with sched_eval," which a bare txs disable breaks. TXS is
an SQ-only concept for hydra (and even SQ is parked).
