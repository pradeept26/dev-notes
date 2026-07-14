# Pulsar TXS (Transmit Scheduler fast-path) Behavior

TXS = **Transmit Scheduler**. On Vulcano the ASIC exposes an SPR
(`__SPRID_TXS_CMD`) that lets the RDMA datapath (running on MPUs) turn the
hardware TX scheduler for a queue **on or off with a single register write**,
instead of the classic doorbell (a memory write the scheduler must then read
and *evaluate*).

- **Fast** (one `__mtspr`) vs the classic doorbell (~4-5 instr + memory latency).
- **Dumb**: it can ONLY flip the scheduler on/off. It cannot evaluate the
  doorbell (i.e. decide whether there is really work). So correctness depends
  entirely on (a) feeding it the exact right lif/qid/cos and (b) never letting a
  "disable" escape without a race-free re-eval behind it.

Definitive source comment: `nic/rudra/src/pulsar/p4/p4plus-16/rdma/include/rdma.h:203-205`
> "txs_cmd is a new feature in Vulcano which provides a fast path from MPUs to
> tx scheduler. It can only be used to turn the scheduler on or off, it can't
> evaluate the doorbell, so its use requires care with races."

## Why it exists

Introduced by `2e6cc1e9fcb` ("pulsar: vulcano: Disable auto-clear to improve
latency, using new vulcano txs_cmd to compensate", PR #107152).

- Scheduler **auto-clear** (HW auto-disables the queue after each PHV launch)
  caused **severe unfairness**: on RTL sim with 4 queues × 128 packets, the
  slowest queue took **61% longer** than the fastest. Unacceptable on a GPU
  cluster.
- Fix: turn auto-clear **OFF** (fair) — but now the pipeline must explicitly
  stop itself when the SQ drains. `txs_cmd` makes that explicit-stop cheap
  enough to avoid a latency regression. **TXS is the enabler for running with
  auto-clear off.**

## The interface

`txs_cmd_doorbell()` — `nic/rudra/src/pulsar/p4/p4plus-16/rdma/include/rdma_util.h:195`

Packs a 32-bit command and writes `__mtspr(__SPRID_TXS_CMD, ...)`:

| Bits    | Field | Meaning |
|---------|-------|---------|
| `[0:0]` | mode  | 0 = doorbell, 1 = rate_limit |
| `[1:1]` | set   | 1 = enable scheduler, 0 = disable |
| `[8:2]` | lif   | full 7-bit LIF; **TXS instance = top bit** of the lif |
| `[22:9]`| qid   | 14-bit **scheduler** qid (NOT the QP id) |
| `[27:24]`| cos  | class of service of the ring being controlled |

Per-pipeline wrapper `_txs_cmd_doorbell(cos, set)` —
`rdma_req_tx/rdma_req_tx_util.h:54`:
- qid source = `p.p4_intr_global.tm_q_depth` (overloaded on TXDMA PHVs to hold
  the source scheduler qid, per Vulcano spec 12.1).
- lif = `LIF_ID_FOR_QTYPE(p.p4_intr_global.lif, p.p4_txdma_intr.qtype)`.

## Datapath flow in rdma_req_tx (the canonical example)

**S0 — speculative fast stop** (`rdma_req_tx_s0_sqcb.p4:255-271`):
```p4
#if RDMA_USE_TXS_CMD
if (next_spec_sq_cindex == SQ_P_INDEX &&           // looks like the last PHV
    __ring_not_empty() == 1 << SQ_RING_ID) {       // nothing else pending
    p.stopped_txs = 1;                             // remember we did this
    _txs_cmd_doorbell(sqcb.q.cosB, false);         // fast-disable scheduler
}
#endif
```
S0 also sets `p.ki_spec_sq_emptied` so S5 can force a spec-resync if the guess
was wrong.

**S6 — race-free correction** (`rdma_req_tx_s6_write_back.p4:76-88`):
```p4
#if RDMA_USE_TXS_CMD
if (p.stopped_txs == 1) {
    // optimistically stopped at s0; qstate is now updated, so make the
    // doorbell engine do its race-free check for whether we should run.
    p.ki_flags.eval_doorbell = 1;
}
#endif
```

Rule: **every S0 `txs_cmd` disable MUST be paired with a guaranteed S6
race-free re-eval**, on every path (including drop / recovery / spec-fail).
`p.stopped_txs` (`rdma_req_tx_phv.h:554`) is the carrier bit S0→S6.

## Bug history (all the same two root causes)

The feature's entire fix trail is either **wrong field fed to txs_cmd** or
**a missing S6 re-eval → hang**:

| Commit | JIRA/PR | Bug | Fix |
|--------|---------|-----|-----|
| `eda0fb5ea4e` | AI-4730 (#111583) | Passed **QP id** as scheduler qid | Use `tm_q_depth` (lif-relative sched qid). Also: single-FRPMR disabled at S0 with no S6 re-eval → model never ran 2nd pass |
| `d699118d00d` | VSW-1004 (#115721) | **LIF split wrong** (6-bit lif in `[8:2]`, instance in bit 23) | Full 7-bit lif in `[8:2]`; instance = top bit. Removed bit-23 write |
| `374e9b9e7df` | (#117823) | **Wrong COS** (`cosA` instead of SQ's `cosB`) | Use `sqcb.q.cosB` |
| `374e9b9e7df` | (#117823) | **Pipeline hang**: fenced WQE → recovery, TXS stopped at S0 but PHV dropped at S5 → S6 re-eval never ran | Always visit S6 during recovery; drop the `spec_initial_failure` gate on the S6 re-eval (re-eval whenever `rate_enforce_failed`) |
| `c2e575ce463` | VSW-1112 | (related) end-of-SQ spec check simplified; introduced the spec-reset/re-eval discipline that (374…) later had to broaden | — |

## Model vs hardware gotcha

On SIM the scheduler will not fire another PHV unless re-eval'd, so a missing
S6 re-eval **deadlocks the model** even where hardware's continuous scheduling
would paper over it. `stopped_txs` distinguishes "disabled only in S0 via
txs_cmd (must re-eval)" from "disabled in S5 for RRQ-full (must stay disabled)"
— see `rdma_req_tx_s6_write_back.p4:396-405`.

## ASIC gating

`RDMA_USE_TXS_CMD` = 1 on Vulcano, 0 on Salina (`rdma.h:200-207`); the
`txs_cmd_doorbell` definition itself is `#ifndef SALINA`
(`rdma_util.h:194,206`). Salina falls back to the classic doorbell entirely.

## Related

- `HYDRA-AUTOCLEAR-BEHAVIOR.md` — hydra's current (auto-clear based) scheme.
- `VULCANO-AUTOCLEAR-CHANGES-NEEDED.md` — the "keep auto-clear always on"
  workaround for Vulcano.
- `HYDRA-TXS-DESIGN.md` — proposed port of this feature into the hydra pipeline
  (the pulsar-style alternative to the auto-clear workaround).

---
**Created:** 2026-07-13
**Source of truth:** `nic/rudra/src/pulsar/p4/p4plus-16/rdma/` (read the code; this
summary can drift)
