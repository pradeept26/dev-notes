# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

P4+ (P4 Plus) dataplane code for the AMD Pensando NIC implementing **Meta RoCE** (RDMA over Converged Ethernet for AI/HPC workloads). The pipeline is named **rudra** and the P4_PROGRAM is **hydra**. Code is compiled to run on the NIC's MPU (Micro Processing Unit) pipeline stages on the **Vulcano** and **Salina** ASICs.

Meta RoCE is a Meta-designed RDMA transport protocol optimized for large-scale AI training clusters. Unlike traditional RoCEv2, Meta RoCE provides multipath load balancing, AIMD+RCN congestion control, selective acknowledgment, and Tag-based stream multiplexing without requiring PFC.

## Architecture

### Pipeline Model

The NIC processes packets through multi-stage P4+ pipelines (up to 8 stages, labeled S0-S7). Each stage runs on a separate MPU, enabling pipelined execution.

**Two DMA engines coexist:**
- **UxDMA** (Unified xDMA) — primary engine, merges RxDMA and TxDMA into a single pipeline. Mandatory for Hydra. Defined in `uxdma.p4`.
- **SxDMA** (Serialized xDMA) — secondary single-pipe engine for admin queues, eDMA, notifications. Defined in `sxdma.p4`.

### Top-level entry point

`rudra_common.p4` → includes `uxdma.p4` and `sxdma.p4` → instantiates the main pipeline with Meta RoCE TX and RX subpipelines.

### Meta RoCE Pipeline Structure

The Meta RoCE implementation lives in this directory with the following structure:

| Subdirectory | Purpose |
|---|---|
| `include/` | Headers: CB structs (SQCB/RQCB/path_cb/CQCB), PHV layouts, opcodes, constants |
| `tx/` | TX pipeline stages (S0-S7): req_tx, path_tx, resp_tx, comp_tx |
| `rx/` | RX pipeline stages (S0-S7): data path, ACK path, feedback |
| `test/` | Test harness shared definitions |
| `docs/` | Protocol and implementation documentation |

### Meta RoCE Processing Paths

Meta RoCE has multiple parallel processing paths through the pipeline:

| Path | Trigger | Purpose |
|------|---------|---------|
| **req_tx** | SQ doorbell (new WQE) | Initiate SEND/WRITE/READ on requester side |
| **path_tx** | Path scheduler doorbell | Retransmission, ACK, timer, CWND retry |
| **resp_tx** | Responder TX trigger | Generate responses (READ data, ACKs) |
| **comp_tx** | RX feedback | Post completions to CQ |
| **rx data** | Incoming packet | Process WRITE/SEND data, validate FSN, deliver to memory |
| **rx ack** | Incoming SAETH | Process ACKs/SACKs, update CWND, advance snd.una |
| **aq_tx** | Admin queue doorbell | Process admin commands (QP create/modify/destroy) |

### Shared RDMA headers

Common headers used across Meta RoCE and other pipelines:
- `meta_roce_headers.p4` — Wire headers (BTH, METH, SAETH, RETH, etc.)
- `meta_roce_defines.p4` / `meta_roce_defines.h` — Opcodes, constants, enums
- `rdma_sqcb.p4` / `rdma_rqcb.p4` — Send/Receive Queue Control Blocks
- `path_cb.p4` — Per-path control block (multipath state)
- `rdma_cqcb.p4` — Completion Queue Control Block
- `rdma_types.p4` / `rdma_types.h` — Common RDMA type definitions

## Code Conventions

### File naming
- Stage files: `meta_roce_{tx,rx}_s{N}.p4` — stage number in the filename
- Each stage file defines `control` blocks for that stage's actions
- PHV definitions: `meta_roce_{tx,rx}_phv.p4`

### Conditional compilation

Key flags and their status in Hydra:

| Flag | Hydra Status | Purpose |
|---|---|---|
| `UXDMA` | **Always defined** (forced by `nic/rudra/src/hydra/Makefile:23`) | Unified xDMA mode (mandatory for Hydra) |
| `HYDRA` | **Always defined** (injected by `Makefile.p4`) | Hydra build target |
| `VULCANO` / `SALINA` | Exactly one defined per ASIC target | ASIC-specific code paths |
| `HW` / `SIM` | One set per build target | Hardware vs simulation |
| `RDMA_DISABLE_MEMORY_ONLY_TABLES` | Set per build profile | Disables memory-only tables for early HW |
| `META_ROCE_ENABLE_RETX_*` | Set in `meta_roce_defines.h:24-32` | Per-target retx feature gates |
| `SXDMA_APPS` | Optional (`SXDMA_APPS=1`) | Serialized DMA applications |

**Note:** `META_ROCE` is NOT a build flag; it's a naming convention for source files only.
For the complete list of flags, grep the Makefile chain
(`mkdefs/Makefile.{pre,post,p4}` and the per-program `Makefile`).

### PHV (Packet Header Vector) aliasing

Space is limited. Fields are overlaid using `@phv_alias()` directives to fit within hardware constraints. Notable aliases in Meta RoCE:
- `meta_roce_meth_t.rdma_hdrs` aliases RETH, RETH+IMM, or IMM-only headers
- TX PHV `comp` flit aliases over SACK bitmap, retx WQE, RNR bitmap
- For complete PHV allocation, read the PHV files
  (`tx/meta_roce_tx_phv.p4`, `rx/meta_roce_rx_phv.p4`) directly.

### Compiler warnings
`--Werror` is enabled. Several warnings are explicitly disabled in the Makefile's `P4C_FLAGS` variable due to known compiler issues or pending cleanup.

## Meta RoCE Critical Conventions

### Predicate Vector
The 14-bit `pred` vector controls stage-level execution. Each stage checks its assigned `pred` bit; if false, the stage's table lookup is skipped. **Always set the right pred bits early** — late changes are too costly.

### Speculation Mechanism
SQCB0 maintains `spec_pi` and `spec_color`. The req_tx path speculatively reads ahead of the committed pi. On failure (e.g., MR violation), the pipeline rolls back via `spec_failure != spec_color`. Don't break this without understanding the rollback chain.

### FSN Immutability
Once an FSN is assigned to a (Tag, Opcode, MSN, POSN) tuple, it MUST NOT be reassigned. BRNR uses FSN migration via `_path_cwnd_migrate_fsn` to move stalled packets to a new FSN — this is the only legitimate FSN reassignment.

### Header Templates (TFP)
Eth+IP+UDP headers come from a per-QP HBM template, not constructed per-packet. Modifying `meta_roce_tfp_template_header.p4` requires updating nicmgr template construction (`docs/04-controlplane.md`).

### Port Bitmap Hierarchy
Multiple port bitmaps must stay consistent (all live in SQCB1):
- `header_template_port_bitmap` (SQCB1): which ports the QP is configured for
- `nonzero_path_port_bitmap` (SQCB1): paths that have done at least one TX
- `active_rport_bitmap` (SQCB1): remote ports advertised live by responder via SAETH

For full hierarchy with rules and invariants, read `include/rdma_sqcb.p4`
(SQCB1 fields) and the `update_path_bmp` action in the TX stages.

## Meta RoCE Key Data Structures

| Structure | Size | Purpose |
|-----------|------|---------|
| `SQCB0` | 64B | Send queue primary state (SQ ring, spec mechanism) |
| `SQCB1` | 64B | Path bitmaps + port bitmaps (header_template_, active_rport_, nonzero_path_, path_, inactive_path_), CC state (QWND), bootstrap state |
| `SQCB2` | 64B | MSN bitmap, header template addr/size, CQCB base, TFP csum profile, dst_qp |
| `SQCB3` / `SQCB4` | 64B each | TX/RX statistics |
| `RQCB0` | 64B | Receive queue primary state, RQ ring |
| `RQCB1` | 64B | MSN bitmap, ACK state, BRNR tracking |
| `RQCB2` / `RQCB3` | 64B each | RX/TX statistics |
| `path_cb0` | 64B | TX scheduler state, doorbell tracking |
| `path_cb1` | 64B | RX FSN bitmap, ACK info, RTT measurement |
| `path_cb2` | 64B | TX state: snd_nxt, CWND, retx ring, RTO |
| `path_cb3` | 64B | SACK state: snd_una, fsn_bitmap, RNR bitmap |

**Total per QP:** 320B SQCB + 256B RQCB + 256B per path × N paths.

For exact field layouts and bit positions, read the CB headers in `include/`
directly. `ASSERT_CORRECT_CB_SIZE` verifies sums at compile time.

## P4+ Coding Rules & Optimization

**MANDATORY**: Before planning, implementing, or reviewing any P4+ code changes, you MUST read both of these files:
1. `nic/p4/docs/p4-coding-rules.md` — coding rules (ALU cost, branch hints, variable sizing, lock hold time, predicate/key-maker budgets)
2. `nic/p4/docs/p4-optimizer-dimensions.md` — optimization dimensions (table types, stage balance, PHV packing, cache efficiency, DMA coalescing, redundant write elimination)

All proposed changes must comply with the coding rules. Optimization dimensions should be evaluated for any performance-sensitive change.

## Documentation

### Protocol and Implementation Docs (`docs/`)

For understanding HOW Meta RoCE works:
- `docs/00-overview.md` — Protocol overview, design goals vs RoCEv2, glossary
- `docs/01-protocol.md` — Wire headers, opcodes, sequence numbers, CC algorithms
- `docs/02-tx-pipeline.md` — TX pipeline narrative (architecture, send path, retx, headers, CC/multipath)
- `docs/03-rx-pipeline.md` — RX pipeline narrative (data path, ACK processing)
- `docs/04-controlplane.md` — Control plane (nicmgr QP/MR lifecycle)
- `docs/05-testing.md` — Test infrastructure (gtest, DOL, P4 unit tests)
- `docs/06-debugging.md` — Debugging workflows and nicctl commands
- `docs/07-feature-status.md` — **Feature status table** (implemented + spec-only, with the PR that last touched each feature)
- `docs/08-asic-differences.md` — **Vulcano vs Salina hardware facts** not visible in source `#ifdef` blocks (e.g., AXI channel count)
- `docs/09-p4-engineering-principles.md` — **Durable P4+ rules** (PHV growth, alias liveness, lock-hold cost, instruction budget, pred-gated writes, compiler ground-truth files, CB byte-overlap, update-protocol writebacks)

**Source is the source of truth.** For CB layouts, PHV fields, opcodes,
stage maps, build flags, and ASIC `#ifdef` blocks: read the source
directly. Per-stage cross-references (which field is written by which
stage and read by which other stage) are best discovered by `grep` —
do not maintain duplicate cross-cutting docs.

## Hydra Skills (`../../../.claude/skills/`)

| Skill | Purpose |
|-------|---------|
| `build` | Build AINIC firmware (Hydra/Pulsar, Vulcano/Salina) |
| `build-gtest` | Build the gtest binary |
| `gtest` | Run hydra gtest test cases |
| `dol` | Run DOL (end-to-end) test cases |
| `pull-assets` | Pull build assets from minio |
| `decode-exception` | Decode MPU exceptions from logs |

## Workflow for Common Tasks

### Adding a CB Field
1. Read the relevant CB header in `include/` directly to find free space
   (look for `rsv*`, `pad*`, `__pad_to_64B` fields). `ASSERT_CORRECT_CB_SIZE`
   verifies all CBs sum to 512b at compile time.
2. Check `// 8B boundary` comments for update protocol alignment.
3. Edit the CB header with the new field + ownership annotation (`// RW S{N}`).
4. Update affected stages.
5. Update nicmgr CB initialization (see `docs/04-controlplane.md`).

### Adding a Stats Counter
Pick the right scope:
- **QP-level**: SQCB3 (TX) or RQCB2 (RX) — direct field assignment in S7 stats action.
- **Path-level**: `path_tx_stats_t` or `path_rx_stats_t` — same pattern in S7.
- **LIF-level**: use `rdma_lif_stats_inc_1`/`_2` macros with `LIF_STATS_*_OFFSET`.

Set a PHV flag in an earlier stage; check it in S7 to increment the counter.

### Adding a New Opcode
1. Define in `include/meta_roce_defines.p4`.
2. Update parser (RX) and dispatch (TX) tables.
3. Add test case (gtest + DOL).

### Tracing a Packet
- TX side: `docs/02-tx-pipeline.md` (section 2 for new WQE, section 3 for retx)
- RX side: `docs/03-rx-pipeline.md` (section 2 for data, section 3 for ACK)
- Wire format: `docs/01-protocol.md` (section 1)

## When to Update Documentation

| Change | Update |
|--------|--------|
| Add/modify opcode | `docs/01-protocol.md` (section 4) |
| Add new processing path | `docs/02-tx-pipeline.md` or `03-rx-pipeline.md` |
| Add test category | `docs/05-testing.md` |
| Discover new debug technique | `docs/06-debugging.md` |
| Algorithm change | `docs/01-protocol.md` (relevant section) + narrative in TX/RX docs |
| **Implement / significantly modify a user-visible feature** | **Add or update a row in `docs/07-feature-status.md` with the introducing PR number** |
| **Implement a previously-unimplemented spec feature** | **Flip the row's status in `docs/07-feature-status.md` from Spec-only to Implemented and record the PR; update relevant protocol/implementation docs** |
| **Discover new spec gap** | **Add a Spec-only row to `docs/07-feature-status.md` with rationale** |

**Rule of thumb:** If the change is about *what* code exists (fields, tables, opcodes), the KB regenerates it. If the change is about *why* something works a certain way, update the narrative docs manually.

## Key Paths Outside This Directory

- `nic/p4plus/` — shared P4+ applications (adminq, eth, edma, notify, ats)
- `nic/rudra/src/lib/p4/p4plus-16/` — shared Rudra P4+ library headers
- `nic/p4/docs/` — shared P4+ coding rules and optimization dimensions
- `nic/p4plus/p4-16/include/defines.h` — global P4+ defines (intrinsic app types)
- `nic/rudra/src/hydra/mkdefs/` — build system (Makefile.pre, Makefile.post, Makefile.p4)
- `nic/rudra/test/hydra/gtest/` — Hydra C++ gtest test cases
- `dol/rudra/test/rdma_hydra/` — Meta RoCE DOL (end-to-end) test cases
