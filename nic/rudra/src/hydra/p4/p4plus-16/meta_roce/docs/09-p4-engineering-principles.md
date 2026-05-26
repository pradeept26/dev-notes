# P4+ Engineering Principles

Durable rules for writing, modifying, and reviewing P4+ code in the Meta RoCE
pipeline. These are principles (not paraphrase of source) — they don't decay
when the code changes.

For coding-rule and optimization references that may exist outside the tree,
see `nic/p4/docs/p4-coding-rules.md` and `nic/p4/docs/p4-optimizer-dimensions.md`
when present.

---

## 1. PHV size grows from access, not declaration. Avoid 8→16 flit growth.

A stage reading or writing a PHV location beyond the last-used offset grows
the PHV. Declaring or naming a field doesn't allocate; only access does.

Avoid growth, especially 8→16 flit. On Vulcano, when the stage register is
configured for 8 flits, **stage N-1 must execute `NEED_16FLIT_PHV(p)` so the
hardware switches to 16-flit mode for stage N**. Salina doesn't need this.

Macro: `nic/p4plus/p4-16/include/p4plus_common.p4:433`.

## 2. PHV aliases require the underlying field to be fully dead — including to the DMA engine.

`@phv_alias` requires the underlying field to be unread, unwritten, **and**
not referenced by any DMA descriptor from the alias-write point onward, on
every pred path that reaches the alias write. Source-grep alone is not
sufficient — a field can look dead in source but still be live to a queued
PHV-to-MEM DMA.

Verification:

- Same-pipeline source grep — TX aliases:
  `git grep '\bp\.<field>\b' tx/*.p4`; RX aliases: same in `rx/*.p4`.
  TX and RX PHVs are separate types, so cross-pipeline grep isn't needed for
  liveness.
- DMA descriptor grep —
  `git grep '<field>' tx/*.p4 common/*.p4 | grep -E 'phv2mem|dma_cmd'`.
  A field consumed by a queued PHV-to-MEM DMA is live even if no source
  statement reads it.
- Confirm post-compile via `gen/p4gen/.../asm_out/<ACTION>_k.h` — shows what
  the compiler actually promoted to a named slot. See rule 6 for the full
  build-tree path.

## 3. Lock-hold cost is `insns_before_writeback`, not total `insn`.

For lock tables (tables with writeback), `phvwr` instructions placed AFTER
the table flush lengthen total action latency but **don't** extend the
locked region.

Guideline: move all `phvwr`s to after the table flush to minimize
instructions under the lock. Not always possible if the value is needed
immediately after the write.

Discovery:

- `insns_before_writeback` reported by capsim in a p4plus-unit-test.
- Or grep generated asm for `tbl.*\.f` (the explicit flush; otherwise
  implicitly flushed at end of the table action).

## 4. Per-stage instruction budget is packet-rate-driven, not "tables".

P4 stage clock is 1500 MHz on Vulcano and Salina. Vulcano (800G) needs
~24 Mpps at 4K MTU for line rate → **62 instructions/MPU/packet** at MTU.

- Vulcano has 6 MPUs/stage; Salina has 4.
- An all-MPU stage has `62 × N_mpu` instructions/packet headroom at MTU.
- Smaller packets (higher Mpps) tighten the budget.
- Per-stage instruction count is the **sum across all tables in that stage**.

Check stage occupancy first before adding work.

Independent of instruction count, **table lookups themselves cost** — the
table engine reads from a memory location that may or may not be in cache.
Balance the number of table lookups across the pipeline rather than
concentrating them in one stage.

Discovery: same p4plus-unit-test capsim output gives total `insn` per action.

## 5. PHV writes are pred-gated; downstream consumers see the value only on pred paths that include the writer.

`pred.X == 1` gates which action runs at a stage. A PHV write in an action
behind `pred.req_tx` is invisible to a downstream consumer behind
`pred.retx_or_cwnd_retry` — the consumer sees stale earlier-stage writes or
zero defaults.

When adding a downstream consumer of a PHV field, trace which earlier-stage
action populates it on each pred path that activates the consumer.

Discovery: `git grep '\bp\.<field>\s*=' tx/*.p4` (or `rx/*.p4`) and check
each writer's enclosing pred path.

Annotate the consumer:

```
// AI-XXXX: depends on S2 <action> populating <field>; not populated on pred.<other> path
```

## 6. Compiler ground-truth files live under the build tree — read them instead of guessing.

Path:
`nic/build/<arch>/<platform>/rudra/<asic>/gen/p4gen/...`
where `<arch>` ∈ `{x86_64, riscv, aarch64}` and `<platform>` ∈ `{hw, sim}`,
depending on the build.

Read these instead of reasoning manually about overlays, ASM, PHV layout, or
table layout:

- `**/asm_out/<ACTION>_k.h` — PHV view the action actually sees (which
  fields/aliases the compiler promoted).
- `**/asm_out/<ACTION>_d.h` — CB view the action actually sees.
- `**/asm_out/<action>.asm` — emitted instructions (look for `tbl.*\.f` for
  writeback boundaries — see rule 3).
- `phv_layout.json` — full PHV slot layout: bit positions and overlays for
  the whole pipeline.
- `table_spec.json` — per-pipeline table specs (per-stage occupancy — see
  rule 4).

## 7. No two tables anywhere in the pipeline may write to the same byte of the same CB.

1B granularity. Two writes from different tables to the same CB byte cause
hardware ordering/race issues and writeback-merge collisions. There is no
compile-time check; the symptom is **runtime CB corruption**.

When adding a table that updates a CB byte, audit the rest of the pipeline
(TX and RX, all stages) for any other table that writes that byte.

## 8. CB writebacks must conform to the update protocol when the d-vector is read in a later stage.

A writeback to a d-vector is update-protocol-compliant if it matches **one**
of:

- 8 bytes naturally aligned, OR
- 4 bytes naturally aligned + any 2 bytes, OR
- 2 bytes naturally aligned + any 3 bytes, OR
- any 4 bytes.

Required when one table writes a d-vector that another stage's table reads.

Enforce via a p4plus-unit-test that asserts
`capsim.is_update_protocol_compliant == True`
(see `tx/test/test_req_tx_sqcb_process.py:231` and
`tx/test/utils.py:54`), or by code inspection.

CB headers tag fields with `// 8B boundary` comments to call out the granule
boundaries that update-protocol-compliant writes need to respect — see
`include/rdma_sqcb.p4:42-43`, `include/path_cb.p4:111-128`.
