---
name: AI-7376 RCCL regression root cause = libionic express-doorbell, NOT firmware
description: int-sar 8N MI355X RCCL a-8→a-10 regression traced to userspace libionic doorbell/expdb inflation; FW/kernel-ionic exonerated; confirmed via asicmon
type: project
originSessionId: 9b846c29-d719-4cdf-b9a7-b64941a3d651
---
# AI-7376 — RCCL a-8→a-10 regression: root cause is libionic (userspace), not FW

**Testbed:** int-sar-clust 8N MI355X (vulcano/hydra), meta_roce IPv6. Handoff doc: `/home/maeaswar/dumps/int-sar-clust-rccl-debug-handoff.md`. Shared with Madan (he did the original a-8/a-10 comparison and concluded "FW root cause" — **that conclusion was wrong**).

**Finding (2026-07-30):** The ~19–26% avg busbw regression (128M all_reduce 263→~100 GB/s) is caused by the **userspace `libionic` RDMA verbs provider**, NOT firmware.

**Why:** FW held at a-8 across all runs; only host SW toggled:
- a-8 FW + a-10 host tools → ~107 (bad); a-8 FW + a-8 host tools → ~131 (good).
- Single-package proof: swapping **only** `libionic1` deb on an otherwise-a-10 stack flips it. a-10 = `39.0.26.07.10.001` (bad), a-8 = `39.0.26.06.3.001` (good). Kernel `ionic` (26.06.28), IPC driver, pds, nicctl all unchanged/cleared.

**Mechanism = express-doorbell (expdb) posting inefficiency.** Binary delta between the two libionic `.so` = only ~288 B of `.text` in the EXPDB/CMB code (`ionic_dv_pd_set_expdb_mask`, `IONIC_EXPDB_MASK`). Confirmed on hardware via **asicmon** (card0, identical 128M load): bad driver issues **~2.7× more Host doorbells (344→935) and ~2.9× more DB-AXI writes** while moving less data → ~7× worse per-byte doorbell overhead. Regression band is 8M–1G (posting-gated); ≤4M latency-bound and ≥2G line-rate are unaffected.

**Source DID change (repo = `pensando/rdma-core`, branch `ionic-rdma`).** The bundle `VERSION.json` is STALE — it records `91edbe01` for BOTH builds, but that's a copy bug. Real range: **a-8 = `91edbe01` (v54.0-192-12, May 15) → a-10 = `b9a08be46` (v54.0-192-35, merged Jul 27)** = ~23 commits. Deb versions 26.06.3→26.07.10 = June→July snapshots confirm. Binary forensics prove it: a-10 `.so` added `malloc` PLT (← `0e343b419` inline-data VLA→malloc/free per WR) and `strdup` PLT (← `1ab513341` strsep/getenv fix), both absent in a-8.

**Top culprit candidates (expdb/posting path, not yet bisected):**
- `bec68b974` (May 19) — init `qp->sq.cmb`/`rq.cmb` from PD in `create_qp_ex` = the CMB/express-doorbell control (`cmb & IONIC_CMB_EXPDB`). Top suspect.
- `6fc0a7eda` — thread-domain LOCKLESS support (RCCL runs `IONIC_LOCKFREE=all`).
- `0e343b419` (Jun 15) — malloc/free per inline-data WR (RCCL uses inline).
- `139412f44` (Jul 25) — extra size to zero-depth queues.

**To pin exactly:** per-commit libionic rebuild bisect over `91edbe01..b9a08be46`, OR ask owners (Allen Hubbe / Abhijit Gangurde / Pablo Cascón) to map 26.06.3→26.07.10 to commits.

**Env workaround RULED OUT (tested 2026-07-30):** `IONIC_EXPDB_MASK` and `IONIC_SQ_CMB/RQ_CMB` do NOT recover a-10 perf. On a-10 at 128M: default ~102, `IONIC_EXPDB_MASK=15`→99, `=0`→87, `IONIC_SQ_CMB=x IONIC_RQ_CMB=x`→101 (good = 263). `IONIC_EXPDB_MAX=16` so mask is 4 bits (0–15). The regression is in libionic posting/batching code, not env-tunable. **Only remediation = pin/downgrade `libionic1` to a-8 `39.0.26.06.3.001` (`dpkg -i --force-downgrade`, no reboot, restores 131/263), or owners fix the a-10 code.**

**How to apply:** For any RCCL/RDMA perf regression on Pensando AI NICs, do NOT assume FW — isolate host SW vs FW by holding one constant. `libionic` swaps cleanly with `dpkg -i --force-downgrade` (no reboot; RCCL picks up the provider .so at next launch). asicmon Doorbell (`Host`/`Local`/`Sched`) + `-v DB` AXI writes are a direct NIC-side proxy for doorbell/expdb efficiency: `source /etc/profile.d/amd_ainic_user_profile_update.sh && sudo -E asicmon` (the `-E` is required).
