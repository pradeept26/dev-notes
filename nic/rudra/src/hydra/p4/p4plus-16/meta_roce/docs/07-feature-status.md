# Meta RoCE Feature Status

**Specification:** Meta-RoCE Protocol for AI Accelerators v0.97 (Draft)
**Last Updated:** 2026-04-30

Single source of truth for what's implemented, what's a known gap, and which PR
last meaningfully touched each feature. Source can tell you what code exists;
it can't tell you *which PR introduced it* without `git blame` archaeology.
This table closes that gap.

**Status legend:** Implemented / Spec-only / Partial.
**Last touched by:** PR number that introduced or last meaningfully changed
the feature. `?` means the introducing PR was not pinpointed during bootstrap
and should be filled in opportunistically by future contributors. Don't guess.

## Feature Table

| Feature | Status | Mechanism / Notes | Last touched by |
|---|---|---|---|
| Relaxed Ordering (PCIe RO on user-buffer DMA) | Implemented | `rd_fence_en` path skips `data_fence` on RECV CQE when RO is enabled; resp-side completion otherwise force-fences. | PR #100424 |
| BRNR (Buffer RNR) — software RNR via path retx | Implemented | RX detects insufficient RWQE credits, sets `path_cb1.rnr_bitmap`, generates `AETH_CODE_BRNR` NAK; sender retransmits after `rnr_timeout`. FSN migration via `_path_cwnd_migrate_fsn`. See `tx/meta_roce_tx_s2.p4`, `docs/03-rx-pipeline.md` §2.7. | PR #102845 (RNR changes); fixes PR #104172 |
| AIMD congestion control | Implemented | AIMD logic on ACK rx; fixed algorithm hardcoded in P4+. CWND adjusted per-ACK in path_cb2. | PR #94269 |
| RCN (Receiver Congestion Notification) | Implemented | RCN rate hints driven from RX into TX; perf and floor-guard fixes layered on top. | PR #111504 (rate hints); PR #107987 (perf); PR #114586 (cwnd floor) |
| Multipath / path bitmaps | Implemented | Per-QP `path_bitmap`, `nonzero_path_port_bitmap`, `active_rport_bitmap`, `inactive_path_port_bitmap` in SQCB1; path scheduler doorbell drives `path_tx`. CWND enforcement per path. | PR #93571 (cwnd enforcement); PR #113891 / PR #114141 (less-paths-than-ports) |
| MSN bitmap / Selective ACK (SACK) | Implemented | MSN bitmap in RQCB1/SQCB2; SAETH carries SACK info; `META_ROCE_ENABLE_RETX_SACK` gates compile. | PR #100538 (CP master); PR #101171 (immediate-SACK fix) |
| Header templates (TFP) | Implemented | Per-QP Eth+IP+UDP header template in HBM; TFP overhead size is ASIC-conditional (Vulcano uses extended PHV intrinsic). nicmgr constructs templates (see `docs/04-controlplane.md`). | PR #86014 (initial req-tx); PR #92960 (IPv6); PR #94991 (icrc) |
| Speculation (`spec_pi` / `spec_color`) | Implemented | SQCB0 maintains speculative pi ahead of committed pi; rollback on `spec_failure != spec_color`. Initial drop with hydra. | PR #84698 (initial commit) |
| `R`/`T` retransmit bits in METH | Implemented | Adds `R`/`T` bits to METH header for retransmit/timer disambiguation on responder. | PR #113403 |
| RTO retx | Implemented | RTO-based retx via `META_ROCE_ENABLE_RETX_TIMERS`; race fixes between RTO retries and ret/rnr fields. | PR #114691 |
| Out-of-order RX handling | Implemented | `META_ROCE_ENABLE_RETX_OOO` enables OOO packet acceptance into FSN bitmap. | `?` (gated by flag in `meta_roce_defines.h`) |
| HRNR (Hardware RNR) | Spec-only | Software BRNR meets perf requirements; avoids per-path HW timer state. RNR recovery bounded by `rnr_timeout`. | n/a |
| Tags (stream multiplexing) | Spec-only | Tag field in METH always 0; MSN/CSN scoped per QP, not per QP+Tag. Multiple QPs provide equivalent functionality. | n/a |
| RNR-Cancel packet | Spec-only | Sender polls via retransmission after `rnr_timeout`. No early-recovery packet type. | n/a |
| In-Protocol Ping (Echo) | Spec-only | Out-of-band diagnostics via nicctl + control-plane health checks. | n/a |
| RDMA Read | Spec-only | Read Request opcodes (0xCC, 0xCD) generate NAK-Invalid-Operation; Read Response opcode (0xCF) reserved unused. Workloads use Write or Send/Recv. | n/a |
| Atomic operations (FetchAdd, CmpSwap) | Spec-only | Atomic Request opcodes (0xD4, 0xD5) generate NAK-Invalid-Operation; Atomic Ack (0xD2) reserved. AtomicETH/AtomicAckETH headers reserved unused. | n/a |
| Programmable congestion control | Spec-only | Fixed AIMD+RCN algorithm hardcoded in P4+. No runtime SW/HW interface for swapping the CC algorithm. | n/a |

## Conditional Compilation Features

Some features are conditionally compiled. For the full list of build
flags, grep the Makefile chain (`mkdefs/Makefile.{pre,post,p4}` and the
per-program `Makefile`). Retransmission feature gates live in
`include/meta_roce_defines.h`:

- `META_ROCE_ENABLE_RETX_COMMON` — Basic retx (always enabled in production)
- `META_ROCE_ENABLE_RETX_TIMERS` — RTO-based retx (production)
- `META_ROCE_ENABLE_RETX_SACK` — SACK-based selective retx (production)
- `META_ROCE_ENABLE_RETX_OOO` — Out-of-order packet handling (production)

Some retx features can be disabled for early HW bringup or testing.

**Dead code:** `RDMA_RNR_RCQ_CREDIT_FEEDBACK` is referenced in
`tx/meta_roce_tx_s0.p4` (3 `#if` guards) but **never defined** in any
shipping build target → dead code. Re-verify with
`grep -rn 'RDMA_RNR_RCQ_CREDIT_FEEDBACK' nic/`.

## How to Update This Document

| When | Action |
|------|--------|
| Implement / significantly modify a user-visible feature | Add or update a row with the introducing PR number. Keep mechanism note to one line. |
| Discover a new spec gap | Add a Spec-only row. |
| Cherry-pick a feature from another transport | Add a row noting the source PR and the porting branch. |
| Land a fix that materially changes how a feature works | Update the existing row's `Last touched by` to chain the new PR (e.g., `PR #X (intro); PR #Y (fix)`). Don't add a fix-only row. |

**Rule of thumb:** if you can't find the PR for a feature you're documenting,
write `?` rather than guess. Future contributors fill in `?` opportunistically.

## Related Documentation

- **Protocol overview:** `docs/00-overview.md` — what Meta RoCE is, design goals
- **Wire protocol:** `docs/01-protocol.md` — packet formats, opcodes, sequence numbers
- **TX implementation:** `docs/02-tx-pipeline.md` — including BRNR handling on sender side
- **RX implementation:** `docs/03-rx-pipeline.md` — including BRNR detection/NAK generation
- **Build flags:** grep the Makefile chain (`mkdefs/Makefile.{pre,post,p4}`)
- **ASIC quirks:** grep `#ifdef VULCANO` / `#ifdef SALINA` across the source tree
- **Hardware facts not visible in source:** `docs/08-asic-differences.md`
