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
