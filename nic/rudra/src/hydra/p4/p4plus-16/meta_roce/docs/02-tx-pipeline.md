# Meta-RoCE TX Pipeline Architecture

**Note:** For bit-level CB field layouts, PHV allocation, DMA slot
assignments, and resource budgets, read the source directly
(`include/`, `tx/meta_roce_tx_phv.p4`, per-stage files).

This document explains the architectural decisions, algorithms, and control flow of the Meta-RoCE TX pipeline. It focuses on **how** and **why** the pipeline works, not on documenting field offsets or constant values.

---

## 1. TX Pipeline Architecture

### 1.1 Pipeline Entry Points

The TX pipeline is triggered by three distinct hardware events:

1. **SQ doorbell** - Software posts a new WQE and rings the SQ doorbell. The hardware schedules a PHV with SQCB0 loaded as the key.

2. **Path scheduler doorbell** - Path timers, SACK events, RTO timeouts, ACK events, or CWND-retry notifications ring a path-CB doorbell. The hardware loads path_cb0 as the key.

3. **Completion feedback** - Control plane (nicmgr) injects a software PHV to the CQ (for completion feedback/barrier) or RQ (for active QP updates) to trigger dataplane actions. The TX pipeline's `generate_feedback()` action re-injects the PHV to RX with appropriate flags (`comp_rx=1` for CQ, `resp_rx_fb=1` for RQ). See `docs/04-controlplane.md` section 2 for details on feedback types and injection flow.

All TX processing runs through a 10-stage pipeline (S0-S9). The pipeline uses predicate gating and stage-skip masks to dynamically disable unused stages, avoiding unnecessary work.

### 1.2 Four Processing Paths

Stage 0 acts as a dispatcher, selecting one of four processing paths based on the qstate address and program counter:

```
                    S0: meta_roce_s0_process_tbl
                    (qstate PC determines action)
                              |
         +--------------------+--------------------+
         |                    |                    |
         v                    v                    v
   req_tx_sqcb_process   path_tx_s0_process   resp_tx_rqcb_process
   (new WQE send)        (retransmit/timer)   (ACK generation)
         |                    |                    |
         v                    v                    v
   S1: WQE decode        S1: retx WQE load    S1: validate RQ state
   S2: path select       S2: SACK process     S2: (drop PHV)
   S3: FSN allocate      S3: FSN restore      S5-S7: ACK headers
   S4-S7: headers+DMA    S4-S7: headers+DMA
```

**req_tx (New WQE Send Path)**  
Triggered when `spec_sq_cindex != pi_0` in SQCB0. This path reads the WQE from the SQ ring, selects a path, allocates an FSN, and constructs the packet headers.

**path_tx (Retransmit / ACK / Timer)**  
Triggered when the path scheduler fires. Four sub-paths exist:
- **ACK ring** (cosA): High-priority ACK transmission when `pi_ack != ci_ack`
- **Retx ring** (cosB): SACK or RTO retransmit when retx ring non-empty
- **CWND retry ring** (cosB): Re-send delayed packets when window opens
- **Timer ring** (cosB): RTO timeout when `pi_timer != ci_timer`

The ACK path uses the high-priority scheduler class (cosA) to minimize ACK latency. The other three share cosB.

**resp_tx (ACK/NAK Generation)**  
Triggered by the RX pipeline posting to the RQCB ring. Validates QP state and drops the PHV after consuming the ring entry. Actual ACK headers are constructed in S5.

**comp_tx (Completion Processing)**  
Triggered by control plane (nicmgr) software PHV injection to the CQ, or by CQ ARM/SARM ring activity. Handles CQE posting for work completions. The nicmgr injects PHVs with feedback types `RDMA_AQ_COMPLETION_FEEDBACK` or `RDMA_AQ_NICMGR_BARRIER` (defined in `include/rdma_types.p4`). The TX pipeline's `rdma_comp_tx_s0_process()` action in `tx/meta_roce_tx_s0.p4` calls `generate_feedback()` to re-inject to RX with `comp_rx=1` for CQE processing. Note: `RDMA_AQ_ACTIVE_QP_UPDATE` uses the **resp_tx** path instead (injected to RQ, not CQ).

### 1.3 Why Speculation?

The TX pipeline speculatively advances the SQ consumer index in S0 before actually reading the WQE in S1. This allows the hardware to schedule the next PHV immediately without stalling for S1 to complete, maximizing pipeline throughput.

**The speculation mechanism solves a fundamental pipeline problem:** If S0 had to wait for S1 to validate the WQE before advancing the index, the hardware could only launch one PHV per multi-stage pipeline traversal. With speculation, multiple PHVs can be in flight simultaneously, each at different stages.

**How speculation works:**
- S0 maintains speculative indices: `spec_sq_cindex`, `spec_msg_posn`, and a 1-bit `spec_color`
- S0 optimistically assumes the current message fits in one packet (sets `flags.last = 1`)
- S1 reads the actual WQE and validates the speculation
- S2 checks for mismatches and initiates rollback if needed
- A `spec_failure` color bit flips when S2 detects failure, causing S0 to restore indices on the next PHV

The speculation color mechanism prevents stale PHVs from processing after a rollback. When S2 detects a failure, it writes the inverted color to `spec_failure[0]`. The next S0 invocation sees the mismatch and calls `_sq_rollback` to restore the last known-good indices.

### 1.4 Predicate-Based Stage Gating

The `pred` field is a 14-bit vector overlaying `p.p4_txdma_intr.app_type`. Each bit gates a specific table lookup in downstream stages. For the complete allocation, grep `pred\.` across `tx/` and `rx/` stage files:

- `pred.req_tx` → S2 fires path selection
- `pred.sqwqe` → S1 fires WQE decode
- `pred.sge0_va2pa` / `pred.sge1_va2pa` → SGE transfer fires VA2PA lookup
- `pred.add_headers` → S5 fires header construction
- `pred.tx_ack` → S2 fires ACK processing
- `pred.retx_or_cwnd_retry` → S1/S2/S3 fire retransmit processing
- `pred.timer` → S3 fires timer processing
- `pred.cq` → S5-S7 post CQE notification
- `pred.update_path_bmp` → S4 updates path bitmaps

When an error is detected, the pipeline clears multiple pred bits simultaneously and sets `p.p4_intr_global.drop = 1`, preventing all downstream work.

---

## 2. New WQE Send Path

### 2.1 Stage 0: QP State Validation and Speculation

**First priority: validate QP state.** The action immediately checks for table errors, PHV errors, or invalid QP state. Only `RDMA_QP_STATE_RTS` (0x03) is valid. Any other state causes immediate drop and scheduler disable.

**Speculation rollback check.** Before advancing speculation, S0 checks `spec_failure[0] != spec_color`. If true, it restores the indices to the last known-good values written by S2 during the previous successful run.

**Why check before advancing?** This ensures that if a previous PHV encountered a spec failure (WQE color mismatch, last-packet misprediction, etc.), the current PHV starts from the correct position rather than continuing from the incorrect speculative state.

**Speculative advancement logic:**
```
if (spec_msg_posn == exp_num_posn):
    # Last packet of current message
    spec_msg_posn = 0
    msn = msn + 1
    spec_sq_cindex = (spec_sq_cindex + 1) % ring_size
    if spec_sq_cindex == 0:
        spec_wqe_color = ~spec_wqe_color
    flags.last = 1
else:
    # More packets remain
    spec_msg_posn = spec_msg_posn + 1
```

The critical insight: `exp_num_posn` is the last known `exp_num_posn` written by S2 from a previous successful pipeline run. On the very first packet of a WQE, both are 0, so S0 speculates that it's a single-packet message. If S1 discovers the message is larger, `flags.last_spec_failed = 1` triggers recovery.

**Scheduler auto-clear handling.** When `sched_auto_clear == 1`, the hardware scheduler clears the queue automatically after launching a PHV. To pipeline-launch the next WQE, S0 must re-ring the eval doorbell. This happens immediately after advancing indices, allowing the next PHV to be scheduled without waiting for this PHV to complete.

**Congestion control state machine entry.** If the QP was idle (`congestion_state == IDLE`) and CC management is enabled, S0 immediately transitions to `FAST_START` and sets `p.fast_start = 1`. This signals S2 to reset QWND and begin the fast-start probing phase.

### 2.2 Stage 1: WQE Decode and Operation Dispatch

**VA2PA hardware lookup.** The WQE address is computed from `cindex * wqe_size` and loaded via a hardware-assisted VA2PA translation set up in S0. This returns the full WQE data structure as the table data.

**Color validation.** The first check in S1 validates `wqe.base.color == spec_wqe_color`. A mismatch means the producer hasn't yet written the WQE (the ring wrapped faster than software could post new WQEs). This sets `wqe_color_mismatch = 1`, which S2 uses to trigger spec rollback.

**Operation dispatch.** Based on `wqe.base.op_type`, the action dispatches to:
- WRITE (plain or with immediate) → `_write_process`
- SEND (plain or with immediate) → `_send_process`
- Other → format error

**Packet fragmentation calculation.** For messages larger than MTU, S1 computes `exp_num_posn = (length / MTU) - 1` (0-based). A single-packet message has `exp_num_posn = 0`. If `exp_num_posn > MAX_POSN`, the WQE length is invalid and an error is triggered.

**Why RETH appears on all WRITE packets.** Unlike IB, where RETH appears only on the first packet, Meta-RoCE includes RETH on all packets of a WRITE message. This simplifies retransmission: the retx path can reconstruct any packet from the saved WQE without needing to track "first packet" state separately.

**Three SGE paths:**

1. **Zero-SGE path** - Either zero-length or inline data. No VA2PA probes. Always single-packet.

2. **One-SGE or Two-SGE fast path** - If the total payload fits in one MTU, set `flags.last = 1`, set up VA2PA probe(s), and exit. These paths avoid the multi-packet fragmentation logic.

3. **FML (Forward Memory List) path** - Multi-packet message. Compute how much of each SGE belongs to the current packet based on `curr_sge_offset = posn * MTU`. Set up VA2PA probes for the packet's portion of the SGE(s).

**Inline data handling.** For payloads up to 32 bytes, the data is copied into the PHV and inserted via phv2pkt DMA. For larger inline data (up to one MTU), a mem2pkt DMA reads directly from the WQE's `inline_data` field. The retx WQE stores the WQE address as `va0` so retransmits can re-read the inline data.

**First/middle/last flag derivation.** In the FML path, these flags are derived from comparing `posn` against `exp_num_posn`:
- `posn == 0` → first
- `posn > 0 && posn < exp_num_posn` → middle
- `posn == exp_num_posn` → last

The critical check: `if (p.flags.last != last) { flags.last_spec_failed = 1; }`. This catches the case where S0 speculated the message was single-packet but S1 discovered it spans multiple packets.

### 2.3 Stage 2: Path Selection and Speculation Validation

**Speculation check.** S2 validates all speculative assumptions:
```
wqe_color_mismatch == 1 ||
flags.last_spec_failed == 1 ||
cindex != exp_sq_cindex ||
retx_wqe.posn != exp_sq_posn ||
msn_outstanding >= MAX_OUTSTANDING_MSN ||
(path_bitmap == 0 && inactive_path_bitmap == 0)
```

On any failure, `_sq_spec_fail_initiate` drops the PHV and writes recovery state to SQCB0. The `sq_spec_color` is checked to avoid writing duplicate recovery state from multiple failed PHVs.

**Why spec validation happens in S2, not S1.** S1 can only validate the WQE contents. S2 has access to SQCB1, which contains `exp_sq_cindex`, `exp_sq_posn`, `exp_sq_msn`, and path bitmaps - all necessary for full validation.

**exp_sq_cindex advancement.** On successful validation with `flags.last == 1`:
```
exp_sq_cindex = (exp_sq_cindex + 1) % ring_size
exp_sq_msn = exp_sq_msn + 1
exp_sq_posn = 0
if (flags.imm || flags.send):
    csn = csn + 1
_sq_doorbell(exp_sq_cindex)
```

The doorbell issues `doorbell_set_cindex` when the queue becomes empty (`exp_cindex == pindex`) or at batch boundaries (every 16 completions). When the queue empties, the ACK request bit is also set.

**exp_num_posn writeback.** S2 writes `exp_num_posn` back to SQCB0 via direct memory write if it differs from the cached value. This feeds S0's speculation on the next PHV.

**Path selection algorithm.** The algorithm varies based on topology:

**Single-port:** Use `__ffsv(path_bitmap, cur_path_id + 1)` to find the next set bit after the current path. If none found, search from bit 0 (wrap). The bitmap is 96 bits, split into a 64-bit lower half and 32-bit upper half.

**Multi-port:** Organize paths into groups (one per port). Use round-robin across port groups:
1. Increment `cur_path_group_index` (wrapping at `num_ports`)
2. Derive `port_index = (start_port_index + path_group_index) % num_ports`
3. When group index wraps to 0, increment `cur_path_group_offset` (position within group)
4. Search the group's bitmap starting from `cur_path_group_offset`

This ensures fair rotation across ports while maintaining per-port path diversity.

**Path quota enforcement.** If `pkts_sent_on_cur_path < max_pkts_on_path`, stay on the current path. Otherwise, select the next path and reset `pkts_sent_on_cur_path = 1`. When the quota is exhausted, set `request_ack = true` to solicit an ACK at each path rotation boundary.

**ACK request bit logic.** The `meth.a` bit is set when:
- Packet quota on current path is exhausted
- Packet is smaller than MTU (last packet or zero-length)
- FSN == 0 (first packet on a new path)
- Queue becomes empty

**Fast-start in S2.** When `p.fast_start == 1` (set by S0 on IDLE→FAST_START):
```
congestion_state = FAST_START
qp_cwnd_whole = 0
qp_cwnd_fraction = 0
```

For each packet sent during fast-start or bootstrap:
```
qp_cwnd_whole_tx++
flags.incr_path_cwnd = 1
qp_cwnd = qp_cwnd_whole + qp_cwnd_whole_tx - qp_cwnd_whole_rx
if qp_cwnd >= fast_start_qwnd_max or qp_cwnd >= total_path_cwnd_max:
    congestion_state = AIMD  # exit fast-start
```

The TX/RX split (`_tx` and `_rx` counters) avoids write-after-write contention between pipelines. The effective CWND is the sum of the base plus TX increments minus RX decrements.

### 2.4 Stage 3: FSN Allocation and Window Enforcement

**PWND calculation.** The per-path window is computed from multiple components:
```
cwnd = path_cb2.cwnd + (cwnd_bootstrap_tx - cwnd_bootstrap_rx)
cwnd += snd_inflate
pwnd = min(cwnd, 1 << log_pwnd_max)
```

- `cwnd`: base per-path window (updated by RX ACK pipeline via AIMD)
- `cwnd_bootstrap_tx/rx`: bootstrap credits granted (TX) vs consumed (RX)
- `snd_inflate`: selectively ACKed packets (out-of-order received, don't consume window)
- `log_pwnd_max`: maximum allowed PWND cap

**Window enforcement modes:**

**Exact enforcement:** When `exact_cwnd_enforce == 1`:
```
outstanding_pkts = snd_nxt - fsn_una
if outstanding_pkts >= cwnd or cwnd_retry == 1:
    cwnd_retry = 1
    snd_max = snd_nxt  # mark where new sends stopped
    allow = false
    # Path is removed from active bitmap
```

The path is blocked until ACKs arrive and window opens. The CWND retry ring is used to resume sending.

**Allow-overshoot mode:** When `exact_cwnd_enforce == 0`:
```
if outstanding_pkts >= cwnd:
    meth.a = 1  # request ACK
    if path_removed_tx != path_removed_rx or outstanding_pkts > pwnd_max:
        remove_active_path = 1
        path_removed_tx = ~path_removed_rx
    cwnd_overflow = 1  # stats
# Packet is still sent
```

The packet is transmitted even when over quota, but the path is removed to prevent further sends. This mode maximizes throughput by never stalling, at the cost of occasional overshoots.

**FSN allocation.** On the normal allowed path:
```
snd_nxt = path_cb2.snd_nxt  # assign current FSN
path_cb2.snd_nxt = snd_nxt + 1  # advance for next packet
# DMA write snd_nxt to path_cb2.snd_nxt_dma_done
```

The FSN is then copied to the METH header and retx WQE. The timestamp is also recorded from the hardware clock.

**FSN == 0 special case.** The first packet on a path always requests an ACK to bootstrap RTT measurement and window feedback.

**Retx ring write.** S3 generates a DMA command to write the retx WQE to HBM:
```
addr = retx_ring_addr + (retx_pi << 6)  # 64-byte entries
# phv2mem DMA from p.retx_wqe
retx_pi = (retx_pi + 1) % ring_size
```

The retx WQE contains everything needed to reconstruct the packet without re-reading the SQ WQE: FSN, MSN, POSN, CSN, SGE addresses/keys/lengths, RETH fields, immediate data, opcode flags, timestamp.

**RTT timestamp.** When `outstanding_pkts == 0` (first packet after idle), S3 updates `last_ack_or_pkt_sent_ts = current_time`. This timestamp is used by the RTO timer to detect when no progress has been made.

### 2.5 SGE Transfer: VA2PA and DMA

**Memory key privilege check.** The VA2PA probe result contains `mr_flags_privileged`. If set:
- Require `priv_oper_enable == 1` (from SQCB0)
- Skip user-key epoch check
- Skip PD check

If not privileged:
- Validate `mr_ukey == sge_ukey` (epoch match)
- If memory window: validate `mr_qp == qid`
- If standard MR: validate `mr_pd == pd`

**Why privileged keys exist.** They're used for internal NIC operations (kernel bypass, zero-copy paths). The privilege check ensures only authorized QPs can use them.

**VA-to-PA resolution: contiguous vs paginated.**

**Contiguous MR:** Single physical address returned. One mem2pkt DMA covers the entire SGE.

**Paginated MR:** Up to 2 physical pages covered per SGE probe:
```
first_page_bytes = min(full_page_size - first_pa_offset, xfer_bytes)
# DMA command 1: first page
xfer_bytes -= first_page_bytes
if xfer_bytes > 0:
    # Data crosses into second page
    # DMA command 2: second page (up to last_pa_length)
```

Each SGE uses 2 DMA slots (slots 7-8 for SGE0, slots 9-10 for SGE1). If the SGE doesn't cross a page boundary, the second slot is a NOP.

**Access violation detection.** Any of these conditions trigger an error:
- VA2PA hardware status error (`probe.pages.sts.err != 0`)
- Privileged key without `priv_oper_enable`
- User-key epoch mismatch
- PD or QP mismatch
- `num_pa == 0` (no pages returned)
- Data extends beyond the mapped region

All errors set `p.p4_intr_global.drop = 1` and skip remaining stages.

---

## 3. Retransmission Mechanisms

### 3.1 Retransmit Ring Design

**Why a separate retx ring?** Re-reading the original SQ WQE for retransmission would require:
1. Keeping the WQE pinned in memory until ACKed
2. Re-executing the entire S1 decode and SGE processing logic
3. Risk of the WQE being overwritten if the SQ ring wraps

The retx ring provides a stable copy that can be read quickly without re-parsing.

**Ring sizing.** The ring size must be at least the bandwidth-delay product. If the ring fills, `fatal_err_retx_full` is set and the QP is flushed to error state. This is unrecoverable.

**Ring index calculation for lookup:**
```
outs_pkt_pos = snd_cur - snd_una  # position of target FSN in window
retx_idx = (outs_pkt_pos + retx_ci) % ring_size
wqe_addr = retx_ring_addr + (retx_idx << 6)
```

`retx_ci` anchors the oldest unACKed position. Adding `outs_pkt_pos` gives the slot for the packet `snd_cur` FSNs ahead of `snd_una`.

### 3.2 Path Retransmit Process (S1)

**Duplicate PHV guard.** When `retx_in_progress == 0` (fresh start), the action checks `p_retx.retx_color` against `path_cb2.retx_color`. If they match, the PHV is a spurious duplicate from the scheduler and is dropped.

**snd.cur initialization:**

**RTO path:** `snd_cur = snd_una` (retransmit everything from the oldest unACKed packet)

**SACK path:** Validate `snd_cur` is within `[snd_una, max_ack_fsn]`. If outside, reset to `snd_una`.

Both cases set `retx_in_progress = 1` and snapshot `snd_nxt_retx = snd_nxt_dma_done`.

**RNR bitmap handling on RTO.** If `rnr_retx_bmap != 0` during RTO, find the last set bit in the bitmap to compute `max_rnr_retx = snd_una + last_rnr_bit`. Clamp `snd_nxt_retx` to this value so the RTO retransmit stops at the last RNR'd FSN rather than continuing past it.

**SACK mode PWND-delay gate.** When `sack_retx_mode == SACK_RETX_MODE_PWND_DELAY`, compute available PWND and check whether `snd_cur` has advanced past `max_ack_fsn - pwnd`. If so, retx is considered done and will resume when window opens.

**snd.cur advancement and WQE address:**
```
outs_pkt_pos = snd_cur - snd_una
retx_idx = (outs_pkt_pos + retx_ci) % ring_size
wqe_addr = retx_ring_addr + (retx_idx << 6)
last_ack_or_pkt_sent_ts = current_time  # refresh RTO timestamp
p_retx.snd_cur = snd_cur
snd_cur = snd_cur + 1  # advance for next PHV
```

**SACK: do not retransmit past max_fsn.** For SACK retransmits, if `snd_cur >= max_ack_fsn`, the retransmit is done.

**RNR retx flag.** After computing `outs_pkt_pos`, check the `rnr_retx_bmap`:
```
if rnr_in_progress == 1 and outs_pkt_pos < 8 and
   rnr_retx_bmap & (1 << outs_pkt_pos) != 0:
    flags.rnr_retx = 1
    p_retx.fsn_una = snd_cur  # FSN UNA for migration
else:
    p_retx.fsn_una = snd_una  # normal UNA
```

**Retransmit done.** When `snd_nxt_retx <= snd_cur`, clear `retx_in_progress`, update `retx_color`, and write the color back to path_cb0 via direct memory write.

### 3.3 RTO Timer Path (S3)

**Idle check.** If `snd_una == snd_nxt` (nothing outstanding), clear `timer_started` and return. No retransmit needed.

**RNR timeout check.** If `rnr_timeout != RNR_TIMEOUT_INVALID`:
```
rnr_timeout_val = (5us << rnr_timeout) * CLK_TICKS_IN_USECS
elapsed = current_time - last_ack_or_pkt_sent_ts
if rnr_timeout == 0 or elapsed >= rnr_timeout_val:
    rnr_timeout = RNR_TIMEOUT_INVALID
    trigger_retx = true
```

The encoding is `5µs << N` for `N in [1..15]`; `N == 0` means immediate retry. This is the RNR backoff timer expiry.

**RTO check:**
```
tm_ticks = current_time[47:0] - last_ack_or_pkt_sent_ts
if (tm_ticks >> CLOCK_FREQ_TS_SHIFT) > rto:
    trigger_retx = true
    is_rto = true
    entropy_sport[13:0] += 1  # rotate entropy on every RTO
```

The RTO value is in microseconds. The shift converts clock ticks to microseconds.

**Port failover on repeated RTO.** If `is_rto && trigger_retx`:
```
if rto_retx_snd_una_count != 0 and rto_retx_snd_una == snd_una:
    # No progress since last RTO
    if rto_retx_snd_una_count == rto_inactivate_count:
        # Inactivate this port, switch to alternate
        port_index = find_alternate_active_port(active_lport_bitmap)
        port_index = port_index
        flags.rto_oport_change = 1
        pred.update_path_bmp = 1
        # Write force_inactivate flags to path_cb3
```

`rto_inactivate_count` defaults to 3. After three RTOs at the same `snd_una`, the path switches port.

**Timer restart.** Unconditionally restart the timer ring with `min_rto` from the table constant.

**Doorbell.** If `trigger_retx`, ring the `TX_RETX_RTO_RING` doorbell to queue a new PHV with `retx_rto_triggered = 1`.

### 3.4 CWND Retry Path (S3)

**Purpose.** When the normal TX path detects `outstanding_pkts >= cwnd` in exact enforcement mode, it rings the `TX_CWND_RETRY_RING` doorbell and snapshots `snd_max` (the frontier at overflow). When window opens, the CWND retry PHV fires and re-sends packets from `snd_nxt` up to `snd_max` using WQEs already saved in the retx ring.

**Window re-check:**
```
outstanding_pkts = snd_nxt - fsn_una
if outstanding_pkts >= cwnd or snd_max_dma_done color mismatch:
    # Still no room or DMA not complete yet
    drop PHV and re-evaluate via doorbell
```

**WQE address:**
```
retx_idx = (snd_nxt - snd_una + retx_ci) % ring_size
wqe_addr = retx_ring_addr + (retx_idx << 6)
snd_nxt += 1
```

**Completion.** When `snd_nxt == snd_max`, `cwnd_retry = 0` and the path is added back to the active bitmap.

**Key difference from retransmit.** CWND retry sends packets that were already assigned FSNs during the normal TX flow. The R-bit and T-bit are **not** set because these are delayed first transmissions, not protocol retransmissions.

### 3.5 RNR Handling

**BRNR vs HRNR.** BRNR (Buffer RNR) provides a bitmap of affected FSNs. HRNR (Hard RNR) is a global QP wait without a bitmap. The TX pipeline distinguishes them by inspecting `rnr_retx_bmap != 0`.

**FSN migration.** When `flags.rnr_retx == 1` (set in S1 when the packet's position matches a set bit in `rnr_retx_bmap`), S3 calls `_path_cwnd_migrate_fsn`:

1. Dedup guard: if `p_retx.fsn_una <= fsn_una`, this FSN was already migrated. Clear `rnr_retx` and fall through to normal retransmit.

2. Advance `fsn_una`:
   ```
   if fsn_una < p_retx.fsn_una:
       fsn_una = p_retx.fsn_una
   ```

3. Allocate a new retx ring slot:
   ```
   p_retx.retx_nxt_addr = retx_ring_addr + (retx_pi << 6)
   retx_pi = (retx_pi + 1) % ring_size
   ```

4. Assign a new FSN:
   - Normal path: `snd_nxt += 1`; DMA to `snd_nxt_dma_done`
   - CWND-retry active: `snd_max += 1`; DMA to `snd_max_dma_done`

**Why FSN migration is needed.** When a BRNR occurs, the RNR'd FSN can never be acknowledged (the receiver will not deliver it). The UNA field in subsequent data packets must advance past the RNR'd FSN to signal the receiver to free that FSN's state. The pipeline re-sends the data under a **new** FSN.

**BRNR UNA advancement.** Subsequent data packets carry `meth.fsn_una = fsn_una` in the METH header. This tells the receiver to free FSN state for all FSNs below `fsn_una`, allowing the receiver's CumulativeFSN to advance past the RNR'd entries.

### 3.6 Port Failover

**Local port failure detection.** In S3, the `active_lport_bitmap` is read from a table constant (hardware link status). The check:
```
if (active_lport_bitmap != 0) and
   ((active_lport_bitmap & (1 << port_index)) == 0)
```

means: the configured port is down but at least one other port is available.

**Entropy sport update.** On **every RTO**, `entropy_sport[13:0]` is incremented by 1. This changes the UDP source port, steering retransmitted packets through a different ECMP path in the network.

**Path deactivation:**
```
flags.inactive_oport_change = 1
pred.update_path_bmp = 1
remove_active_path = 1
force_inactivate = 1
# Write to path_cb3.force_inactivate_flags
```

The `pred.update_path_bmp` predicate causes S2 to update `path_bitmap` (active) and `inactive_path_bitmap`.

**Switching to next available port:**
```
port_index = __ffsv(active_lport_bitmap, current_time % bitmap_size)
if port_index == -1:
    port_index = __ffsv(active_lport_bitmap, 0)  # fallback
port_index = port_index[2:0]
```

`__ffsv` finds the first set bit starting at a random offset (using low bits of timestamp), providing probabilistic load spreading across available ports.

### 3.7 Retransmit Opcode Setup (S4)

**R-bit and T-bit:**
```
if tx_cwnd_retry_triggered == 0:
    meth.r = 1  # always set for retransmit
    if retx_rto_triggered == 1:
        meth.t = 1  # additionally set for RTO
```

CWND retry packets are **not** marked with R/T because they are first transmissions of already-assigned FSNs.

**Opcode reconstruction:**
```
if write:
    opcode = WRITE
    if imm: opcode = WRITE_IMMDATA  # last packet
    if imm_opcode: opcode = WRITE_IMM  # non-last
elif send:
    opcode = SEND
    if imm: opcode = SEND_IMMDATA
```

**METH fields from retx WQE:**
```
meth.msn = retx_wqe.msn
meth.posn = retx_wqe.posn
meth.fsn = retx_wqe.fsn  # original FSN (not new)
meth.timestamp = current_timestamp  # fresh timestamp
meth.a = 1  # always request ACK on retransmit
```

**RETH (WRITE only):**
```
reth.va = retx_wqe.reth_va
reth.rkey = retx_wqe.reth_rkey
reth.length = retx_wqe.reth_length
```

All packets of a WRITE message carry identical RETH fields.

**Payload re-resolution:**
```
if va0 != 0:
    sge0_raw_addr = va0
    sge0_bytes = len0
    sq_sge0_key.sge0.key = key0[RDMA_KEY_ID]
    pred.sge0_va2pa = 1  # trigger VA2PA

if inline_data_vld:
    pred.sge0_va2pa = 0
    # mem2pkt DMA from va0 (pointer into WQE in SQ ring)
```

**RNR retx (FSN migration).** For `rnr_retx == 1`, the action sets the new retx ring slot address and updates the saved WQE's FSN to the newly assigned FSN.

---

## 4. Header Construction

### 4.1 MSN Completion Tracking (S5)

**Contiguous completion case.** When the incoming MSN equals `bmsn` (oldest outstanding MSN) and `msn_bitmap == 0` (no gaps):
```
bmsn += 1
# Every 16th MSN: write back to sqcb1.sq_bmsn
if bmsn[3:0] == 0xf:
    memory_write(sqcb1_addr + offset(sq_bmsn), bmsn[15:0])
```

**Non-contiguous case.** When the MSN is ahead of `bmsn` (a gap exists):
```
pos = retx_wqe.msn - bmsn[15:0]
# Set bit at position `pos` in msn_bitmap (256 bits)
table_write_indirect(512 - msn_bitmap.size - offset(msn_bitmap) + pos, 0, 1)
```

**Gap collapse.** When the incoming MSN equals `bmsn` but `msn_bitmap != 0` (out-of-order completions already arrived), use `__ffcv` (find first clear bit) on successive 64-bit slices to count contiguous set bits:
```
num_contig = __ffcv(msn_bitmap[63:0], 0)
# Repeat on [127:64], [191:128], [255:192] if needed
msn_bitmap >>= num_contig
bmsn += num_contig
memory_write(sqcb1_addr + offset(sq_bmsn), bmsn[15:0])
```

**MSN vs CSN.** MSN is per-message and assigned at WQE post time. CSN is per-WQE-consuming operation (SEND and WRITE_WITH_IMM only). Completions are ordered by MSN ascending. The `bmsn` bitmap enforces that a completion is not signalled until all lower MSNs have also completed.

**Retransmit MSN check.** For retransmits, S5 checks whether the MSN being retransmitted has already been acknowledged end-to-end:
```
if circular_le16(meth.msn, ack_msn):
    retx_dup_msn = 1  # suppress this retransmit in S6
```

A retransmit of an already-ACKed MSN is dropped because the peer's RQ buffer for that MSN may have been reclaimed.

**Rate hints pre-computation (ACK path).** When `pred.tx_ack == 1 && pred.rcn == 1`, S5 reads the active queue counter pair from HBM and computes:
```
active_queues = byteswap(active_qp) - byteswap(inactive_qp)
line_rate = table_constant[RCN_RATE_HINTS_BITS]  # Gbps
rate_hints = (line_rate * num_active_ports) / (active_queues * num_ports)
# Round up if remainder != 0
saeth.rate_hints = rate_hints
```

This provides the receiver's TargetRate (RCN signal) for inclusion in ACK packets.

### 4.2 Header Dispatch Architecture

**Why a master/slave architecture?** SQCB2 holds the header template address, destination QP, checksum profile, and MSN bitmap - all needed by all header-building variants. A single table lock on CB2 is required. Rather than duplicating the CB2 read across three separate tables, the pipeline uses a single master table that acquires the lock and dispatches to a slave table via `table_pc`.

**Dispatch mechanism.** `table0_raw_addr.table_pc` is a 28-bit field set in S1 (or S4 for retransmit) pointing to one of:
- `meta_roce_tx_add_roce_send_headers` (SEND path)
- `meta_roce_tx_add_roce_write_headers` (WRITE path)
- `meta_roce_tx_add_roce_ack_headers` (ACK path)

The selector is implicit through which PC was stored - determined by `flags.send` / `flags.write` / `pred.tx_ack`.

### 4.3 SEND Headers

**BTH construction:**
```
bth.dest_qp = sqcb2.dst_qp
bth.path_id = (path_qid - sqcb2.path_qid_base)
bth.src_qp = p4_txdma_intr.qid
bth.opcode = SEND (0xC0) or SEND_IMMDATA (0xC1) on last packet
```

`path_id` is derived from the path's hardware queue ID minus the base QID for this QP's paths, giving a 0-based path index.

**METH field assembly.** Most METH fields are set in earlier stages:
- `fsn` - S3 (from `snd_nxt` pre-increment)
- `fsn_una` - S3 (from `max(snd_una, last fsn_una)`)
- `posn` - S0 (from `spec_msg_posn`)
- `csn` - S2 (from SQCB1)
- `msn` - S0 (from SQCB0)
- `a`, `r`, `t` - S3/S4 (based on path conditions)
- `rate_hints` - Piggy-backed from SQCB2 or computed in S5

**Timestamp handling.** In production hardware, `meth.timestamp` is **not written from the PHV**. Instead, DMA slot 3 issues a mem2pkt command that reads 4 bytes from a hardware clock register. This ensures accurate timestamps without PHV propagation delays.

**Immediate data.** When `flags.imm == 1` on a SEND, the immediate data word is in `meth_imm.immdt` (PHV alias over `meth.rdma_hdrs`). DMA slot 4 includes this 4-byte field.

Header size: 32 bytes (12 BTH + 40 METH - 20 rdma_hdrs region). With immediate: 36 bytes.

### 4.4 WRITE Headers

**BTH construction.** Identical to SEND for dest_qp, path_id, src_qp. Opcode:
- `WRITE` (0xC6): plain WRITE (all packets)
- `WRITE_IMM` (0xC7): WRITE_WITH_IMM non-last packets
- `WRITE_IMMDATA` (0xC2): last packet of WRITE_WITH_IMMEDIATE

**RETH construction.** RETH is present on **all** packets of a WRITE message (unlike IB). The RETH fields are set in S1 from the WQE (or restored in S4 from retx WQE):
```
reth.va = wqe.write.va
reth.rkey = wqe.write.r_key
reth.length = wqe.write.length
```

DMA slot 4 includes the RETH (16 bytes) or RETH+ImmDt (20 bytes for last packet with immediate).

Header size: 48 bytes (plain WRITE), 52 bytes (WRITE_WITH_IMM last packet).

### 4.5 ACK Headers

**SAETH field construction.** SAETH fields are assembled by the resp-rx path before this action runs:
```
bth.opcode = SACK (0xD1)
bth.path_id = (path_qid - sqcb2.path_qid_base)
bth.dest_qp = sqcb2.dst_qp
saeth.port_bitmap = active_lport_bitmap & sqcb2.header_template_port_bitmap
```

SAETH fields populated upstream (by resp-rx pipeline):
- `cumulative_fsn` - from `path_cb1.ack_cfsn`
- `max_fsn` - from `path_cb1.max_fsn`
- `ack_status` - ACK_SYNDROME or BRNR_SYNDROME
- `cdmsn` - from `path_cb1.ack_cdmsn`
- `cnp` - from `path_cb1.rsp_rx_ecn_count`
- `echo_ts` - echoed from received `meth.timestamp`
- `rate_hints` - computed in S5

**ACK status selection.** The code uses `flags.sack` and `flags.sack_with_rnr` to select the DMA variant:
- `sack_with_rnr == 1`: FSN bitmap + RNR bitmap (BRNR)
- `sack == 1`: FSN bitmap only (SACK)
- Neither: ACK only (20-byte SAETH, no bitmap)

**RNR timeout encoding.** The `ack_status` byte encodes the timeout as `BRNR_SYNDROME | rnr_timeout` where `rnr_timeout` is 5 bits (`5µs << N`). This is set by the resp-rx path. The TX pipeline doesn't modify this field.

**SACK bitmap assembly.** The 256-bit SACK bitmap is a PHV alias over `comp` (flit 3). It's populated by resp-rx before resp-tx runs, from `path_cb1.fsn_bitmap` shifted to be relative to `cumulative_fsn + 1`.

**ACK DMA slot selection.** ACK packets use slot 7 for the SAETH DMA command, not slot 2. This avoids conflict with S6, which also writes slot 1 (template). For piggybacked ACKs (ACK in data packet), slot 2 is used.

Header sizes: 32 bytes (plain ACK), 64 bytes (SACK), 96 bytes (SACK+RNR).

### 4.6 TFP Header Templates (S6)

**What TFP solves.** TFP (Templated Frame Processor) uses a pre-built header in HBM containing the complete Ethernet + IP + UDP header for each QP and port. The pipeline reads this template via DMA, avoiding per-packet L2/L3 field construction.

**Checksum profiles.** The four base Meta RoCE profiles:
- 0: ETH (14B) + IPv4 (20B) + UDP (8B) = 42B template
- 1: ETH (14B) + 802.1Q (4B) + IPv4 (20B) + UDP (8B) = 46B
- 2: ETH (14B) + IPv6 (40B) + UDP (8B) = 62B
- 3: ETH (14B) + 802.1Q (4B) + IPv6 (40B) + UDP (8B) = 66B

S6 configures TFP header fields:
```
tfp_templated_header.csum_profile = tfp_csum_profile
# len2: IP total length (IPv4) or IPv6 payload length
# len3: UDP length
# crc_start, crc_end, crc_loc: mCRC range (BTH to end of payload)
```

**l3_start_offset.** This is the byte offset of the IP header within the template. For untagged: 14. For VLAN: 18.

Used only for ACK packets to split the template DMA so the ACK DSCP byte can be overridden:
```
# DMA 1: ETH (+ optional VLAN): 0 .. l3_offset bytes
# DMA 2: ACK DSCP override: template[80..81] (2 bytes)
# DMA 3: Rest of IP + partial UDP: l3_offset + 2 .. template_size - 8
```

For data packets, the template DMA is a single mem2pkt of `template_size - UDP_HDR_SIZE` bytes (omitting UDP, which the PHV provides).

**Template address calculation:**
```
header_template_addr = sqcb2.header_template_addr +
                       port_index * (AT_ENTRY_SIZE_BYTES >> 3)
# In S6, shifted to final HBM address:
hdr_template_addr = header_template_addr << 3
```

Per-port entry size is 96 bytes. The stored address is divided by 8 for storage, multiplied by 8 for use.

### 4.7 DMA Command Orchestration (S6)

**Normal data packet layout:**
```
[P4 intrinsics + TFP hdr][ETH+IP][UDP][BTH][METH][TS][RETH/IMM][payload][padding][ICRC]
```

Key DMA commands:
- Slot 0: P4 intrinsics + TFP header (40B + 26B) - always
- Slot 1: ETH+IP template (mem2pkt, no UDP) - data packets
- Slot 2: UDP + BTH + METH (4B + 12B + 20B) - data packets
- Slot 3: Timestamp (mem2pkt from hw clock register) - always (data)
- Slot 4: RETH or IMM (16B or 20B or 4B) - WRITE or SEND+IMM
- Slot 5: Retx WQE (phv2mem to retx ring) - data packets (S3)
- Slot 6: snd_nxt or snd_max update (phv2mem) - data packets (S3)
- Slots 7-10: Payload SGEs (mem2pkt, 2 SGEs × 2 pages) - payload present
- Slot 11: Padding (phv2pkt, 1-3 bytes) - payload len % 4 != 0
- Slot 12: ICRC placeholder (phv2pkt, 4B) - always (hardware fills)

**ACK packet DMA.** ACK packets use 3-part template DMA in slot 1 to inject ACK-specific DSCP. SAETH and bitmaps go in slot 7.

Slots 5 and 6 are **not** used for pure ACK packets (no retx WQE save, no snd_nxt update). Slots 2, 3, 4 are also unused (SAETH replaces METH).

**Loopback path.** When `ud_loopback == 1`, the packet is redirected to the local RX pipeline. The DMA construction differs:
- Loopback builds RX intrinsics in slot 0
- No TFP header (loopback doesn't go through wire TFP)
- Slot 2 covers only `meth.fsn .. meth.rate_hints` (no UDP fields)

---

## 5. Congestion Control and Multipath

### 5.1 CC State Machine

**Three states:**
- `IDLE` (0): No outstanding traffic
- `FAST_START` (1): Probing phase after idle period
- `AIMD` (2): Normal congestion control via additive increase / multiplicative decrease

The state is stored in two places:
- `sqcb0.congestion_state` (authoritative, read by S0)
- `sqcb1.congestion_state` (working copy, read/written by S2)

These are in different cache lines to avoid contention. S2 writes to both when transitioning.

**IDLE → FAST_START.** S0 triggers when first packet arrives after idle:
```
if congestion_state == IDLE and congestion_mgmt == 1:
    congestion_state = FAST_START
    p.fast_start = 1
```

S2 reacts by resetting QWND to zero:
```
congestion_state = FAST_START
qp_cwnd_whole = 0
qp_cwnd_fraction = 0
```

**FAST_START → AIMD.** S2 checks on every packet:
```
qp_cwnd_whole_tx++
qp_cwnd = qp_cwnd_whole + qp_cwnd_whole_tx - qp_cwnd_whole_rx
flags.incr_path_cwnd = 1
if congestion_state == FAST_START:
    fast_start_qwnd_max = 1 << log_fast_start_qwnd_max
    total_path_cwnd_max = max_paths * (1 << log_pwnd_max)
    flags.fast_start = 1
    if qp_cwnd >= fast_start_qwnd_max or qp_cwnd >= total_path_cwnd_max:
        congestion_state = AIMD
```

Exit conditions (either triggers transition):
1. QP window has grown to configured maximum
2. All paths at their individual max window

### 5.2 QWND / PWND / AWND Hierarchy

**QWND storage.** The QP-level window is split across SQCB1 fields:
- `qp_cwnd_whole`: Integer part (updated by RX ACK pipeline)
- `qp_cwnd_fraction`: Fractional part (sub-packet epsilon increments)
- `qp_cwnd_whole_tx`: TX shadow (increments per packet sent in fast-start)
- `qp_cwnd_whole_rx`: RX shadow (increments per ACK received)

Effective QWND: `qp_cwnd_whole + qp_cwnd_whole_tx - qp_cwnd_whole_rx`

The TX/RX shadow split avoids locked read-modify-write between pipelines.

**PWND per path.** Per-path window in `path_cb2_t`:
- `cwnd`: Base per-path window (packet count)
- `cwnd_bootstrap_tx/rx`: Bootstrap credits
- `snd_inflate`: Selectively ACKed packets (don't consume window)
- `log_pwnd_max`: Cap on maximum PWND

Effective PWND from `_get_pwnd` (S3):
```
cwnd = path_cb2.cwnd + (cwnd_bootstrap_tx - cwnd_bootstrap_rx)
cwnd += snd_inflate
pwnd = min(cwnd, 1 << log_pwnd_max)
```

**AWND formula (as coded).** From `_window_check` in S3:
```
outstanding_pkts = snd_nxt - fsn_una
# Allow if outstanding_pkts < cwnd (== PWND including inflate)
```

This implements: `AWND[p] = PWND[p] + snd.inflate[p] - (snd.nxt[p] - snd.una[p])`

`fsn_una` is maintained as `max(snd_una, last fsn_una)` to account for RNR-migrated FSNs.

**Window increment (additive increase).** Performed in RX pipeline when non-congested ACK arrives, using epsilon and log_beta from SQCB0.

In TX pipeline, QWND increase during fast-start is `qp_cwnd_whole_tx++` per packet (epsilon=1). PWND increase during bootstrap is `cwnd_bootstrap_tx++` per packet, matched by `cwnd_bootstrap_rx++` on ACK.

**Window decrement (multiplicative decrease).** Performed by RX pipeline on congested ACK:
- Beta: `QWND = QWND - (QWND >> log_beta_shift)`
- Lambda: `QWND = QWND - (N >> log_lambda_shift)` for N losses

PWND decremented proportionally. When PWND reaches 0, path is inactivated.

### 5.3 Fast Start Implementation

**snd.inflate per path.** Count of FSNs between `snd_una` and `snd_nxt` that have been selectively ACKed. These packets are in-flight but already received. The AWND formula includes `snd_inflate` to avoid counting them against the window.

Updated by RX ACK pipeline when processing SACK bitmaps. TX pipeline adds it to base CWND before comparing against outstanding.

**bootstrap_port_bitmap.** One bit per port group, set when that port is in bootstrap phase. The full set of port bitmaps and their consistency invariants live in `include/rdma_sqcb.p4` (SQCB1) and the `update_path_bmp` action in the TX stages.

Used in `_bootstrap_needed`:
```
if num_ports > 1:
    # If any active port not in bootstrap bitmap, trigger new bootstrap
    if (active_port_bitmap & bootstrap_port_bitmap) != active_port_bitmap:
        bootstrap = true
        force_bootstrap = 1
```

Detects newly active ports needing path bootstrap.

**nonzero_path_port_bitmap.** One bit per port group, set when at least one path on that port has nonzero PWND.

Used in port bitmap computation:
```
active_port_bitmap = active_lport_bitmap & active_rport_bitmap &
                     header_template_port_bitmap & nonzero_path_port_bitmap
```

Excludes port groups with no bootstrapped paths (all at PWND=0).

**Fast-start packet ordering.** Implementation achieves interleaving by:
1. Send `fast_start_burst` packets on path 0 (bootstrap_in_progress)
2. When `pkts_sent_on_cur_path == fast_start_burst`, set `bootstrap_done=1`, find next unstarted path in `inactive_path_bitmap`
3. Move newly selected path from inactive to active (via S4 bitmap update)

`force_bootstrap` ensures strict port-group ordering by finding groups with fully-inactive bitmaps.

**Bootstrap phase end.** When `pkts_sent_on_cur_path == fast_start_burst` in bootstrap:
```
flags.upd_inactive_path_bmp = 1
pred.update_path_bmp = 1
remove_inactive_path = 1
add_active_path = 1
bootstrap_done = 1
bootstrap_in_progress = 0
request_ack = true
```

S4 processes bitmap updates: clear bit in `inactive_path_bitmap`, set bit in `path_bitmap`. Path transitions from bootstrap to normal active operation.

If `cwnd <= 0` after bootstrap (no ACKs arrived), path isn't moved to active - stays inactive.

**Fast-start exit via QWND_max.** In S2 during fast-start:
```
qp_cwnd = qp_cwnd_whole + qp_cwnd_whole_tx - qp_cwnd_whole_rx
if qp_cwnd >= fast_start_qwnd_max or qp_cwnd >= total_path_cwnd_max:
    congestion_state = AIMD
```

### 5.4 RCN Rate Hints

**Data packet rate_hints.** Computed in S5 from `sqcb2.rate_hints` (14 bits). Represents sender's estimate of current transfer rate:
```
rate_hints ≈ QWND × 4096 × 8 / RTT  [Gbps, clamped to link capacity]
```

When zero (end of transfer or fast-start first packet), receiver ignores the field.

**ACK packet rate_hints.** Represents receiver's TargetRate (RCN signal). Set by RX pipeline into `path_cb1_t` fields. TX pipeline copies verbatim into packet via S5 headers.

Formula: `TargetRate = TotalLinkRate / EstimatedConcurrentSenders + TargetRateOffset`

Active-queue counter read provides `EstimatedConcurrentSenders` signal.

### 5.5 Multipath Selection Algorithm

**Single-port algorithm:**
```
start_offset = cur_path_id + 1
bitmap = path_bitmap (or inactive_path_bitmap if bootstrapping)
# Search bitmap[0..63] from start_offset
path_id = __ffsv(bitmap[63:0], start_offset & 0x3f)
if path_id == -1:
    # Search upper half [64..95]
    path_id = __ffsv(bitmap[95:64], 0) + 64
if path_id == -1:
    # Wrap around from bit 0
    path_id = __ffsv(bitmap[63:0], 0)
```

`__ffsv(bitmap, offset)` is hardware find-first-set-bit starting at position `offset`. Bitmap is 96 bits (max paths), split 64-bit lower + 32-bit upper.

**Multi-port algorithm.** Paths organized into groups (one per port). Round-robin across port groups:
```
foreach port (i in 0..num_ports):
    path_group_index = (path_group_index + 1) % num_ports
    port_index = (start_port_index + path_group_index) % num_ports
    
    if active_port_bitmap has port_index:
        path_group_bitmap = bitmap[group * max_paths_per_port:
                                   +max_paths_per_port] & mask
        if path_group_bitmap != 0:
            break

path_id = __ffsv(path_group_bitmap, cur_path_group_offset)
# Final: path_group_index * max_paths_per_port + relative_path_id
```

**Group advancement:**
```
path_group_index = (path_group_index + 1) % num_ports
if path_group_index == 0:
    # Wrapped all ports: advance within-group offset
    cur_path_group_offset = (cur_path_group_offset + 1) % max_paths_per_port
```

Ensures fair rotation across ports while maintaining per-port path diversity.

**Path quota enforcement.** If `pkts_sent_on_cur_path < max_pkts_on_path`, stay on current path. Otherwise select next path and reset counter. When quota exhausted, set `request_ack = true`.

**Bitmap interactions:**
- `active_rport_bitmap`: Remote port active status (from received ACK Active Port Set)
- `path_bitmap`: Paths with nonzero PWND receiving traffic
- `inactive_path_bitmap`: Configured paths not yet activated (PWND=0)
- `header_template_port_bitmap`: Ports with valid header template
- `nonzero_path_port_bitmap`: Ports with at least one path having nonzero PWND

Effective: `active_port_bitmap = active_lport_bitmap & active_rport_bitmap & header_template_port_bitmap & nonzero_path_port_bitmap`

### 5.6 Path Bootstrap Activation

**Bootstrap trigger.** `_bootstrap_needed` in S2 evaluates:
```
if bootstrap_in_progress: return false

# Multi-port: new port became active
if num_ports > 1 and
   (active_port_bitmap & bootstrap_port_bitmap) != active_port_bitmap:
    return true; force_bootstrap = 1

# AIMD: enough CWND to add path
qp_cwnd = qp_cwnd_whole + qp_cwnd_whole_tx - qp_cwnd_whole_rx
num_active_path = max_paths - num_inactive_path
if congestion_state == FAST_START or
   (congestion_state == AIMD and num_active_path == 0) or
   (congestion_state == AIMD and
    ((num_active_path+1) << avg_window_shift) < qp_cwnd):
    if (num_active_path + num_down_path) < max_paths:
        return true
```

`avg_window_shift` approximates: `(num_active_path + 1) << shift ≈ fast_start_burst × (active_path_count + 1)`. When this is less than `qp_cwnd`, adding a new path makes sense.

**Bootstrap sequence.** S2 checks color bit to serialize bootstrap events:
```
if bootstrap_s2 == bootstrap_s4:
    bootstrap_in_progress = 1
    bootstrap_s2 = ~bootstrap_s2
    flags.bootstrap = 1
else:
    # Another bootstrap pending in S4; drop this one
    force_bootstrap = 0
    _sq_spec_fail_initiate
```

With `bootstrap_in_progress = 1`, path selection switches to `inactive_path_bitmap` and `pkts_sent_on_cur_path` tracks against `fast_start_burst`.

**First packet constraint.** First packet on new path must be first packet of message (`posn == 0`) per protocol requirement. Implementation enforces indirectly through SQ check.

**snd.inflate boosting.** When `flags.incr_path_cwnd == 1`, S3 increments `cwnd_bootstrap_tx`:
```
if flags.incr_path_cwnd == 1:
    if flags.bootstrap == 1:
        entropy_sport[13:0]++  # new entropy for new path
    cwnd_bootstrap_tx++
    # Result: effective PWND = cwnd + cwnd_bootstrap_tx - cwnd_bootstrap_rx + snd_inflate
    allow = true  # bypass window check
```

Pre-grants one slot of window per packet sent during bootstrap. Matching `cwnd_bootstrap_rx++` happens on ACK (RX pipeline), draining bootstrap credit.

**Port failover interaction.** When `rto_retx_snd_una_count == rto_inactivate_count` (repeated RTO at same `snd_una`):
```
active_port_bitmap = active_lport_bitmap & ~(1 << port_index)  # exclude current
port_index = __ffsv(active_port_bitmap, random_start)  # pick alternate
port_index = port_index
flags.rto_oport_change = 1
force_inactivate = 1
# Write to path_cb3: force_inactivate + DECR_QP_CWND flags
```

Triggers:
1. Path removed from `path_bitmap`
2. QP CWND decremented (RX pipeline when flag processed)
3. `entropy_sport` incremented (changes UDP source port for ECMP)
4. Next bootstrap picks new port's inactive paths

Link-down detection triggers port reassignment in S3 using same mechanism, without waiting for RTO count.

---

## Summary: Pipeline Stage Responsibilities

**S0: Entry point and dispatcher**
- QP state validation
- Speculation rollback check
- Speculative index advancement
- CC state IDLE→FAST_START transition
- Scheduler auto-clear doorbell management

**S1: WQE decode and operation dispatch**
- VA2PA hardware lookup for WQE
- WQE color validation
- Operation-specific processing (WRITE/SEND)
- Packet fragmentation calculation
- SGE fast-path vs FML selection
- Retransmit WQE load (retx path)

**S2: Path selection and spec validation**
- Speculation check and rollback initiation
- exp_sq_cindex/posn advancement
- exp_num_posn writeback to SQCB0
- Path selection (single-port or multi-port)
- Path quota enforcement
- Fast-start QWND management
- Bootstrap trigger detection

**S3: FSN allocation and window enforcement**
- PWND calculation
- Window enforcement (exact or allow-overshoot)
- FSN allocation and assignment
- Retx ring WQE write
- RTT timestamp recording
- RTO timer processing
- CWND retry processing
- RNR FSN migration

**S4: Path bitmap updates and retx opcode setup**
- Path bitmap add/remove operations
- Bootstrap completion processing
- Retransmit opcode reconstruction
- RNR retx FSN patching

**S5: MSN tracking and header dispatch**
- MSN completion bitmap management
- Gap collapse processing
- Rate hints computation (ACK path)
- Header template setup
- Master/slave table dispatch

**S6: TFP template and DMA orchestration**
- TFP header configuration
- Template DMA command generation
- DSCP override for ACKs
- Loopback path handling
- mCRC range setup

**S7: Statistics and error handling**
- Per-message/packet counters
- Path management counters
- QP error disable processing
- LIF statistics updates

This architecture balances pipeline depth, speculation depth, and lock contention to maximize throughput while maintaining correct RDMA semantics and congestion control behavior.
