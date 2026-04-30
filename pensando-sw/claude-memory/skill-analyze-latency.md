---
name: analyze-latency skill
description: RDMA latency analysis skill using mputrace with external loopback - learned from sanshanb's share-with-team directory
type: reference
originSessionId: b14f63d0-44d0-496b-a0fa-98e2d332b9eb
---
Skill `/analyze-latency` installed at `~/.claude/skills/analyze-latency/SKILL.md`.

**What it does:** End-to-end RDMA latency analysis using MPU trace with external MAC loopback via macvlan namespaces. Measures per-stage pipeline timing breakdown for req_tx and resp_rx paths.

**Source:** Learned from `/home/sanshanb/share-with-team/SKILL.md` on 2026-04-29.

**Key workflow phases:**
1. Setup: NIC discovery (show_gid, nicctl), enable MAC loopback, create macvlan namespaces
2. Collect: Configure mputrace (uxdma pipeline), run ib_write_lat between namespaces, dump trace binary
3. Decode: Generate symbols with saltrace.py gen_syms, decode with saltrace.py decode_mpu
4. Analyze: Find Nth packet (default 4th), extract phv_timestamp_capture, build timing table (Salina: 1.1 GHz, 1 tick = 0.909 ns)
5. Report: 5-block half-RTT breakdown (Host→NIC, req_tx S0→S7, NIC turnaround, resp_rx S0→S7, NIC→Host)
6. Cleanup: Remove namespaces, disable MAC loopback

**Important notes:**
- Verify `sqcb0.loopback = 0` during test — if 1, firmware bypasses TFP/MAC/TID path
- In external loopback, req_tx and resp_rx have **different** phv_timestamp_capture values
- `trace: true` and `phv-debug: true` require firmware instrumentation (`__trace(1)` in S0 programs); set both to `false` if not instrumented
- The skill references supporting docs at `~/.claude/docs/debugging/` which need to be created or obtained from sanshanb

**How to apply:** Use when profiling RDMA latency on Salina/Vulcano NICs, identifying pipeline bottlenecks, or comparing performance across firmware versions.
