# ASIC Platform Differences

Hardware-level differences between Vulcano and Salina that affect how Meta
RoCE is implemented but are NOT visible in source as `#ifdef VULCANO` /
`#ifdef SALINA` blocks. For the code-level conditionals themselves,
grep `#ifdef VULCANO` / `#ifdef SALINA` directly across the source tree;
this doc covers the hardware facts that motivate them (and the ones that
don't show up in code at all).

## Host AXI Channels

**Vulcano: 2 channels. Salina: 1 channel.**

Writes issued on different AXI channels can complete out of order on Vulcano.
Salina is in-order by construction (single channel).

**Implication:** resp-side CQEs that follow a user-buffer DMA need an explicit
`data_fence` (or `fence_fence`) on Vulcano so the application sees the buffer
landed before the completion. Salina does not.

**Where it shows up:** `meta_roce/common/rdma_comp.p4` — RECV CQE forces
`data_fence=1` in the else-branch of the `rd_fence_en` (relaxed-ordering)
path, gated by `#ifdef VULCANO`. Ported from Pulsar PR #113217. When
`rd_fence_en` is enabled the if-branch already orders via `fence_fence`, so
the per-CQE `data_fence` is gated off there.

## Adding to This Doc

Use this doc when you discover a hardware-level fact about Vulcano or Salina
that:

1. Is not derivable from source (so the KB generator can't pick it up).
2. Affects how Meta RoCE is implemented now or could constrain future
   implementations.

Don't use this for `#ifdef VULCANO` / `#ifdef SALINA` blocks themselves —
read those from the source directly with `grep -rn '#ifdef VULCANO\|#ifdef SALINA'`.

Format: short heading per topic, one-line summary in bold, the consequence
and where-it-shows-up in prose. Cite source files when known.
