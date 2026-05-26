# Meta RoCE RX Pipeline

This document describes the RX pipeline architecture, data path processing, and ACK path processing for Meta RoCE. It focuses on control flow, state machine logic, and decision-making algorithms rather than field-level implementation details.

> **Note**: For PHV/CB field mappings, DMA slot assignments, and
> constant values, read the source directly (`include/`,
> `rx/meta_roce_rx_phv.p4`, per-stage files).

---

## 1. RX Pipeline Architecture

### 1.1 Pipeline Entry and Dispatch

Incoming Meta RoCE packets (UDP port 2766) are steered to the `meta_roce_rx` P4+ program. ASIC-specific code paths are gated by `#ifdef VULCANO` / `#ifdef SALINA`:
- **Salina**: TID (Transaction ID) steers packets to RxDMA
- **Vulcano**: P4 pipeline steers packets to RxDMA

Before entering the RxDMA pipeline, the packet is parsed, the `meta_roce_rdma_app_header_h` app header is constructed, and `p4_rxdma_intr.qstate_addr` is set to the address of the QP's RQCB (for data packets) or SQCB (for ACKs).

The top-level control flow:

```p4
@app("meta_roce_rx")
control meta_roce_rx(inout meta_roce_rx_phv_t p) {
    apply {
        meta_roce_rx_dma.init(dma_loc);
        meta_roce_rx_s0.apply(p);   // RQCB/SQCB
        meta_roce_rx_s1.apply(p);   // RQCB1 / path_cb3 (SACK)
        meta_roce_rx_s2.apply(p);   // path_cb1 / SQCB1 (CC) / WQE VA2PA
        meta_roce_rx_s3.apply(p);   // MSN context / path_cb2 (RTO)
        meta_roce_rx_s4.apply(p);   // VA2PA resolution + payload DMA
        meta_roce_rx_s5.apply(p);   // MSN completion / ACK generation
        meta_roce_rx_s7.apply(p);   // Statistics
    }
}
```

**Note**: Stage 6 is the shared `rdma_comp` pipeline (CQE posting).

### 1.2 App Header Dispatch (S0)

Stage 0 inspects `app_hdr` flags to select the processing path:

```
Incoming packet on UDP:2766
         |
         v
  +------+------+
  | app_hdr     |
  | resp_rx?    |--YES--> Data Path (WRITE/SEND/ReadResp)
  | ack?        |--YES--> ACK Path (SAETH: ACK/SACK/BRNR/NAK)
  | resp_rx_fb? |--YES--> Feedback Path (admin completion)
  +------+------+
```

| `app_hdr` flag | Table applied | Purpose |
|---|---|---|
| `resp_rx == 1` | `resp_rx_rqcb_process_tbl` | Incoming data packet |
| `ack == 1` | `req_rx_sqcb_process_tbl` | Incoming SAETH (ACK/SACK/BRNR/NAK) |
| `resp_rx_fb == 1` | `resp_rx_rqcb_process_tbl` | Admin/feedback from firmware |
| `comp_rx == 1` | `rdma_comp_rx_s0_t0` | Completion feedback |

The dispatch is mutually exclusive: only one flag is set per PHV.

### 1.3 RQCB Lookup (Data Path)

For data packets (`resp_rx == 1`), S0 reads `rdma_rqcb0_t` from the address written by the NPU based on `dest_qp` in the BTH. Key validation:

- **QP State**: Must be `>= RDMA_QP_STATE_RTR`; below this, the PHV is dropped
- **Path ID**: Must be `< max_paths`; invalid path triggers `NAK_CODE_PATHID_UNS`
- **Path CB Address**: Computed as `path_cb_base_addr + (path_id << shift)`

The pipeline computes path control block address and prepares for per-path processing in subsequent stages.

### 1.4 Processing Paths Overview

| Stage | Data Path (resp_rx) | ACK Path (ack) |
|---|---|---|
| **S0** | Read RQCB0, validate state, compute path_cb_addr | Read SQCB0, extract CC params, compute path_cb_addr |
| **S1** | Read RQCB1, RNR check, MSN allocation | Read path_cb3, PAWS check, snd.una advancement, FSN bitmap |
| **S2** | FSN validation (path_cb1), RQWQE VA2PA (SEND) | CC update (SQCB1), AIMD/RCN rate hints |
| **S3** | MSN context tracking (pkt_count) | Path state update (path_cb2), RTO computation, NAK handling |
| **S4** | VA2PA resolution, payload DMA (wire→host) | (skipped) |
| **S5** | MSN bitmap update, ACK generation | MSN completion bitmap, CQE generation |
| **S7** | RX stats (RQCB2) | ACK stats (SQCB4), path stats |

---

## 2. Data Path Processing

### 2.1 Data Path Overview

Handles opcodes: `0xC0` (Send), `0xC1` (Send+Imm), `0xC6/C7/C2` (Write/Write+Imm), `0xCF` (ReadResp).

**High-level flow**:

```
Wire Packet (BTH + METH + [RETH] + Payload)
    |
    v
S0: RQCB0 validation
    - Check QP state >= RTR
    - Validate path_id < max_paths
    - For WRITE: compute destination VA = reth.va + (posn * MTU)
    - For SEND: launch RQWQE fetch via VA2PA
    |
    v
S1: RNR check and MSN allocation
    - For SEND: verify CSN within posted RWQE range (RNR check)
    - Duplicate MSN detection (msn < bmsn)
    - Compute MSN context address for S3
    |
    v
S2: FSN validation (path_cb1)
    - In-order: advance rcv_nxt
    - Out-of-order: set bit in fsn_bitmap
    - Duplicate: set flags.dup
    - Out-of-range: set flags.fsn_oor, NAK_FSN_OOR
    - ECN CE (ecn==3): increment rsp_rx_ecn_count
    - Populate ack_info for ACK generation
    |
    v
S3: MSN context (pkt_count tracking)
    - First packet: initialize pkt_count = msg_len/MTU
    - Intermediate packets: decrement pkt_count, suppress delivery
    - Last packet: set flags.msn_completed, trigger CQE if needed
    |
    v
S4: VA2PA and payload DMA
    - Validate R_Key, MR permissions, VA bounds
    - Emit pkt2mem DMA commands (wire payload → host PA)
    - RCCL: split write with RO LIF override + RD fence
    |
    v
S5: MSN completion and ACK generation
    - Advance bmsn (base MSN) via msn_bitmap
    - Write cumulative rcq_csn to host memory
    - Generate ACK: write ack_info to path_cb1, ring doorbell
    - Update active QP counter
    |
    v
S6 (rdma_comp): CQE posting
    - Post CQE to host CQ if pred.cq == 1
    - Generate EQE if CQ armed
    |
    v
S7: Statistics
    - Update RQCB2 counters (num_pkts, num_bytes, etc.)
    - Update LIF stats
```

### 2.2 FSN Validation State Machine (S2)

The core FSN validation logic in `path_rx_cb_process` (S2) implements a sliding window state machine:

**States**:
- `rcv_nxt`: Next expected in-order FSN
- `max_fsn`: Highest FSN seen (in-order or out-of-order)
- `fsn_bitmap`: 256-bit sliding window tracking out-of-order arrivals

**Transitions**:

```
Case 1: In-order (fsn == rcv_nxt && rcv_nxt == max_fsn + 1)
    → Fast path: rcv_nxt++, max_fsn++
    → Generate ACK if meth.a == 1

Case 2: Duplicate (fsn < rcv_nxt)
    → Set flags.dup, clear app_hdr.resp_rx
    → Skip S3/S4 delivery
    → Generate immediate ACK

Case 3: Out-of-range (fsn >= rcv_nxt + 256)
    → Set flags.fsn_oor
    → Status = NAK_FSN_OOR
    → Drop (if nak_prune) or send NAK

Case 4: Out-of-order in-window (rcv_nxt < fsn < rcv_nxt + 256)
    → Set bit (fsn - rcv_nxt) in fsn_bitmap
    → Update max_fsn if fsn > max_fsn
    → When rcv_nxt arrives: count contiguous set bits, advance rcv_nxt
```

**UNA (Una) advancement**: The sender embeds its `snd.una` in `meth.fsn_una`. The receiver validates this against contiguous set bits in `(fsn_bitmap | rnr_bitmap)` before advancing `rcv_nxt` to match:

```
if (fsn_una > rcv_nxt):
    shift = fsn_una - rcv_nxt
    num_contig = count_contiguous_set_bits(fsn_bitmap | rnr_bitmap)
    if shift > num_contig:
        → Invalid, drop packet (flags.invalid_fsn_una_shift)
    else:
        → Advance rcv_nxt by shift + additional contiguous bits
```

This enforces the protocol rule: the sender can only skip FSNs that have already been accounted for.

### 2.3 SEND vs WRITE Dispatch

**WRITE Path**:
- Destination VA carried in RETH header: `reth.va`
- POSN-indexed offset: each packet computes `va = reth.va + (posn * MTU)`
- Enables relaxed-order delivery without NIC reordering
- VA2PA launched in S0 with `va_cmd_key0`
- No RWQE fetch required

**SEND Path**:
- Destination buffer determined by posted RWQE
- CSN (Consumer Sequence Number) selects RWQE: `csn & ring_mask`
- RWQE fetched in S2 via `resp_rx_rdma_rqwqe_va2pa`
- SGE extraction for up to 2 SGEs
- POSN-based offset into SGE buffer: `sge_va + (posn * MTU)`

**Decision tree in S0**:

```
if (rdma_raw_flags & RESP_RX_FLAG_WRITE):
    → WRITE path
    → va_cmd_key0 = reth.va + (posn * MTU)
    → pred.rqsge0 = 1

elif (rdma_raw_flags & RESP_RX_FLAG_SEND):
    → SEND path
    → Launch RQWQE fetch: va_cmd_key0 = (csn << lg2_rq_wqe_sz)
    → pred.rqwqe = 1
```

### 2.4 MSN Packet Counting (S3)

Each MSN (Message Sequence Number) spans one or more packets. The MSN context slot tracks:

- `pkt_count`: Countdown of packets remaining
- `completion_needed`: Whether to post CQE (SEND or Write+Imm)
- `op_type`: CQE opcode (RECV_SEND, RECV_SEND_IMM, RECV_RDMA_IMM)
- `immdt`: Immediate data (32-bit)

**Algorithm**:

```
On first packet (pkt_count == 0 on entry):
    exp_num_pkts = ceil(msg_len / MTU)
    pkt_count = exp_num_pkts
    completion_needed = 0  // set if SEND or Write+Imm

On each packet:
    pkt_count--
    if (pkt_count != 0):
        clear app_hdr.resp_rx  // suppress S5 delivery
        return

On last packet (pkt_count == 0 after decrement):
    flags.msn_completed = 1
    if (completion_needed):
        flags.completion_needed = 1
        Setup CQE fields, set pred.cq
```

Only the **last packet** of a multi-packet message triggers MSN bitmap advancement and CQE posting.

### 2.5 Memory Protection and VA2PA (S4)

**VA2PA probe response processing** (`resp_rx_rdma_rqsge0/1`):

1. **VA2PA error check**: `probe.common.sts.err != 0` → error handler
2. **PA count check**: `num_pa == 0` → `resp_rx_va2pa_page_validation_fail`
3. **User key check**: `mr_ukey != ukey` → `resp_rx_key_check_fail` (NAK_CODE_ACC_ERR)
4. **Access flag check**:
   - SEND: require `mr_access_local_write`
   - WRITE: require `mr_access_remote_write`
5. **Size validation**: For paged MR, handle cross-page boundary with two DMA commands

**Payload DMA construction**:

- Standard case: single `pkt2mem` DMA with RO (Relaxed Ordering) LIF override
- RCCL RD fence case: split transfer at 256-byte boundary
  - First N-256 bytes: RO LIF (relaxed ordering)
  - Last 256 bytes: regular LIF (strict ordering)
  - Emit read-fence `phv2mem` to force PCIe write flush
  - Fence CQE on read fence to ensure data visibility before completion

### 2.6 ACK Generation and MSN Completion (S5)

**MSN bitmap advancement**:

```
if (flags.msn_completed):
    pos = meth.msn - bmsn
    Set bit pos in msn_bitmap
    num_contig = find_first_clear_bit(msn_bitmap)
    if (num_contig != 0):
        bmsn += num_contig
        msn_bitmap >>= num_contig
```

`bmsn` (base MSN) is the cumulative completed MSN at the responder — the responder-side equivalent of `snd.una`.

**ACK generation decision**:

```
if (flags.resp_rx_gen_ack):
    if (IS_NAK(ack_info.status)):
        ack_info.cdmsn = meth.msn  // failing MSN for NAKs
    else:
        ack_info.cdmsn = msn_nxt - 1  // cumulative CDMSN for ACKs

    // Pack ack_info and write to path_cb1
    Write ack_info to path_cb1.ack_cfsn (64-bit packed)
    
    // Ring doorbell to schedule resp_tx
    Ring doorbell on META_ROCE_TX_ACK_NAK_RING
```

The resp_tx pipeline reads `ack_cfsn` from `path_cb1` and constructs the SAETH packet. Data is passed via shared memory, not PHV.

**Cumulative CSN DMA**:

When all pending MSNs complete in order:
```
rcq_csn = exp_csn - 1
Emit phv2mem DMA: write rcq_csn to rcq_base_addr
```

Out-of-order MSN completion is tracked separately with `ooo_msn_received`, `ooo_csn_count`, and `max_rcqe_msn`.

### 2.7 RNR (Receiver Not Ready) Handling

**BRNR (Buffer RNR) Detection** (S1):

```
For SEND or Write+Imm:
    csn = meth.csn
    total_posted = (pi_rq - exp_csn) & ring_mask
    if (csn - exp_csn >= total_posted):
        → Set flags.rnr
        → Cancel WQE fetch (pred.rqwqe = 0)
        → Cancel VA2PA (pred.rqsge0 = 0)
```

**RNR Bitmap Tracking** (S2):

```
if (flags.rnr && fsn within 8-bit RNR window):
    Set bit (fsn - rcv_nxt) in rnr_bitmap
    Populate ack_info with BRNR status
    Clear app_hdr.resp_rx  // skip S3/S4 delivery

if (fsn outside 8-bit RNR window):
    Drop silently
```

The `rnr_bitmap` in `path_cb1_t` is an 8-bit bitmap of FSNs that were RNR'd. The receiver's `rcv_nxt` cannot advance past an RNR'd FSN until the sender advances its `fsn_una` past those FSNs.

**RNR ACK Generation** (S5):

```
if (flags.rnr):
    ack_info.status = BRNR | rnr_timeout
    If rnr_bitmap_valid:
        Include rnr_bitmap in outgoing SAETH
```

### 2.8 Error Path

**Error Detection Sources**:

| Error | Stage | Action |
|---|---|---|
| VA range out of bounds | S4 | `resp_rx_key_va_write_fail` / `_send_fail` |
| Key state invalid | S4 | `resp_rx_key_state_write_fail` / `_send_fail` |
| User key mismatch | S4 | `resp_rx_key_check_fail` (NAK_CODE_ACC_ERR) |
| Access flag violation | S4 | `resp_rx_access_fail` / `resp_rx_key_access_ctrl_fail` |
| Invalid WQE format | S2 | `resp_rx_invalid_wqe_format_fail` |
| Insufficient SGE space | S2 | `resp_rx_insuff_sge_fail` |

**Error Handling Behavior**:

All responder-side error helpers share a common pattern:
1. Set `comp.err_disable_qp = 1`
2. Set `comp.cqe.err = 1` and populate error status
3. Set `pred.cq = 1` to trigger CQE posting
4. Clear `pred.rqsge0/rqsge1` and `pred.resp_rx_msn_comp` to skip delivery
5. Populate `ack_info.status` with NAK code

In S7, when `comp.err_disable_qp == 1`:
```
Set error bit in RQCB (table_write_indirect)
Set QP state to RDMA_QP_STATE_ERR
```

**NAK vs Error Completion**:

| Scenario | NAK sent | Error CQE | QP disabled |
|---|---|---|---|
| Duplicate FSN | Yes (repeat ACK) | No | No |
| FSN OOR | Yes (NAK_FSN_OOR) | No | No |
| Invalid path_id | Yes (NAK_PATHID_UNS) | No | No |
| R_Key/VA error | Yes (NAK_ACC_ERR) | Yes (if completion_needed) | Yes |
| Access flag error | Yes (NAK_OP_ERR/NAK_ACC_ERR) | Yes | Yes |
| RNR (BRNR) | Yes (BRNR status) | No | No |

For WRITE without immediate, memory errors do not post a receive CQE (`completion_needed == 0`). The error is only reflected in the SAETH NAK and EQ events.

---

## 3. ACK Path Processing

### 3.1 ACK Path Overview

Handles opcode `0xD1` (Selective ACK). The SAETH header carries:
- Cumulative FSN (highest in-order FSN delivered)
- FSN bitmap (256-bit SACK bitmap)
- CNP count (ECN CE count)
- CDMSN (cumulative delivered MSN)
- Rate hints (RCN capacity estimate in Gbps)
- Echo timestamp (for RTT measurement)
- Port bitmap (active remote ports)

**High-level flow**:

```
Wire Packet (BTH + SAETH + [FSN bitmap] + [RNR bitmap])
    |
    v
S0: SQCB0 validation
    - Check QP state == RTS
    - Extract CC parameters (epsilon, log_beta, gamma, omega)
    - Compute path_cb_addr
    |
    v
S1: SACK processing (path_cb3)
    - PAWS check: drop if rtt_ticks > 64 * current_rtt
    - Update smoothed RTT (current_rtt)
    - Advance snd.una from SAETH cumulative_fsn
    - Store FSN bitmap (byte-swapped to liblsmr format)
    - Count snd_inflate (SACK holes for CC)
    - Ring doorbell on SACK retx ring if needed
    |
    v
S2: CC update (SQCB1)
    - Update active_rport_bitmap
    - Sync qp_cwnd_whole from TX-side
    - Exit fast-start on first ACK
    - RCN: adjust qp_cwnd_max from rate_hints
    - Update QP-level RTT (rtt_qp)
    - AIMD CC:
        * CNP or SACK holes → multiplicative_decrease
        * Uncongested → additive_increase
    |
    v
S3: Path state update (path_cb2)
    - Handle BRNR: set rnr_timeout, flags.rnr
    - Handle NAK: error handlers (disable QP on ACC_ERR/OP_ERR)
    - Update snd_inflate, max_ack_fsn
    - Advance snd.una (path_cb2 copy)
    - Advance retx_ci (retx ring consumer index)
    - Per-path PWND update: cwnd +1 or -decr_pwnd_val
    - Path inactivation: move to inactive_path_bitmap if cwnd → 0
    - Per-path RTO computation (rtt_p, rtt_mdev, rto)
    |
    v
S5: MSN completion (SQCB2)
    - Advance ack_msn from SAETH cdmsn
    - Post send completion CQE if cdmsn advanced
    |
    v
S7: Statistics
    - SQCB4: num_acks, num_rx_rnr_naks, CC event counts
    - path_rx_stats: num_rx_acks, RTT buckets, CNP count
```

### 3.2 SACK Bitmap Processing (S1)

**Bitmap format conversion**:

The SAETH carries a 256-bit `fsn_bitmap` in big-endian network order. S1 converts it to little-endian for internal processing by byte-swapping each 32-bit word to conform to liblsmr format.

**Bitmap semantics**: Bit `i` is set if FSN `(cumulative_fsn + 1 + i)` has been received. A zero bit means that FSN is missing.

**snd.una advancement**:

```
if (saeth.cumulative_fsn >= snd_una):
    num_pkts_acked = (cumulative_fsn + 1) - snd_una
    snd_una = cumulative_fsn + 1
```

This frees retx ring entries. The path-level `snd_una` is updated in both `path_cb3_t` (S1) and `path_cb2_t` (S3).

**SACK hole counting**:

The `_num_sack_holes` helper counts zero-bits in the bitmap across all four 64-bit words. The result is `snd_inflate` (number of missing FSNs above `cumulative_fsn`):

```
snd_inflate = last_snd_inflate + (last_fsn - start_fsn - num_zeros)
```

Optimization: if `snd_una` has not moved (pure SACK), counting resumes from `last_inflate_fsn` using saved `last_snd_inflate` instead of rescanning from the beginning.

**SACK-triggered retransmission**:

When the SACK bitmap is non-zero and SACK retransmit mode is enabled, the RX pipeline doorbells the TX path:

```
if (sack_retx_mode != DISABLE && bitmap != 0 && brnr_bitmap == 0):
    Toggle rx_retx_in_progress
    Ring doorbell on META_ROCE_TX_RETX_SACK_RING
```

The `rx_retx_in_progress` / `tx_retx_in_progress` toggle prevents scheduling a new SACK retransmit while one is already in progress (lock-free coordination).

### 3.3 RTT Measurement and RTO Computation

**Path-level RTT (path_cb3_t, S1)**:

A preliminary smoothed RTT for PAWS check:

```
rtt_ticks = current_time - echo_ts
current_rtt = current_rtt - (current_rtt >> 3) + (rtt_ticks >> 3)
```

Alpha = 1/8 (EWMA with shift 3). Units are raw hardware clock ticks.

**Per-path full RTT (path_cb2_t, S3)**:

```
rtt_meas = rtt_ticks >> (CLOCK_FREQ_TS_SHIFT - 3)  // convert to 1/8 us

// Smoothed RTT (SRTT)
rtt_p = rtt_p - (rtt_p >> alpha_p_shift) + (rtt_meas >> alpha_p_shift)

// Mean deviation (mdev)
mdev_meas = |rtt_meas - rtt_p|
rtt_mdev = rtt_mdev - (rtt_mdev >> beta_shift) + (mdev_meas >> beta_shift)

// RTO calculation
rto = (rtt_p + 4 * rtt_mdev) >> 3  // convert 1/8 us → us
rto = clamp(rto, min_rto, max_rto)
rto = max(rto, rtt_meas)  // floor at measured RTT
```

`rtt_p` and `rtt_mdev` are in 1/8 us units. `rto` is stored in microseconds and consumed by TX timer logic.

**QP-level RTT for CC (SQCB1, S2)**:

```
rtt_qp = rtt_qp - (rtt_qp >> alpha_p_shift) + (rtt_meas >> alpha_p_shift)
```

Used in RCN rate-hint conversion to CWND.

### 3.4 Congestion Control (AIMD and RCN)

**Decision tree in S2 (`req_rx_ack_process`)**:

```
req_rx_ack_process (S2, rdma_sqcb1_t):
  ├── Update active_rport_bitmap from SAETH port_bitmap
  ├── Sync qp_cwnd_whole from TX-side qp_cwnd_whole_tx
  ├── Fast-start state? → transition to AIMD, return
  ├── RCN mode?
  │   └── adjust_qwnd_from_rate_hint (compute qp_cwnd_max from rate_hints)
  ├── Update rtt_qp
  ├── SACK holes or CNP? → multiplicative_decrease, return
  ├── num_pkts_acked == 0? → return
  ├── decr_pwnd_val != 0? → return (RCN decrease)
  ├── path_cwnd >= max_pwnd? → return (already at cap)
  └── Additive increase: additive_increase
```

**Additive Increase**:

```
if (epsilon > qp_cwnd_whole):
    // Bootstrap: immediate +1 if window is tiny
    qp_cwnd_whole += 1
    flags.incr_pwnd = 1
else:
    add_incr = epsilon * num_pkts_acked
    qp_cwnd_fraction += add_incr
    if (qp_cwnd_fraction >= qp_cwnd_whole && rtt_meas <= rtt_qp):
        qp_cwnd_fraction -= qp_cwnd_whole
        qp_cwnd_whole += 1
        flags.incr_pwnd = 1
```

- `epsilon`: AI increment parameter (from SQCB0)
- `qp_cwnd_fraction`: fractional accumulator
- `flags.incr_pwnd = 1` propagates to S3, which increments `path_cb2.cwnd` by 1 (up to `log_pwnd_max`)

**Multiplicative Decrease**:

Triggered when `num_sack_holes != 0` (SACK-loss CC) or `saeth.cnp != 0` (ECN/CNP):

```
count = num_sack_holes or CNP count
log_const_shift = log_lambda (SACK) or log_beta (CNP)

decr_qwnd_val = count >> log_const_shift  // integer part
decr_qwnd_rem = count & shift_mask         // fractional remainder
mul_decr = (qp_cwnd_whole >> log_const_shift) * decr_qwnd_rem

// Apply fractional part to qp_cwnd_fraction
qp_cwnd_whole -= decr_qwnd_val
```

Guard prevents decreasing below `qwnd_min`.

**RCN Rate Hints**:

When `rcn == 1` and `rate_hints != 0`:

```
// Convert rate_hints (Gbps) to CWND
effective_rate_hint = (rate_hints * active_port_count) / active_rport_bitmap_popcount
cwnd_in_bytes = (gamma * rtt_qp * effective_rate_hint) >> 4
cwnd = cwnd_in_bytes >> lg2_mtu
qp_cwnd_max = cwnd  // ceiling for qp_cwnd_whole
```

If `qp_cwnd_whole > qp_cwnd_max`:
```
if (qp_cwnd_whole > qp_cwnd_max * 2):
    decr_pwnd_val = num_pkts_acked  // fast decrease
else:
    decr_pwnd_val = num_pkts_acked >> 1  // slow decrease
```

**Per-path PWND update** (S3):

```
if (flags.incr_pwnd):
    if (cwnd < max_pwnd):
        cwnd += 1
elif (decr_pwnd_val != 0):
    cwnd -= decr_pwnd_val
    if (cwnd <= 0 && cwnd_retry != 1):
        // Move path to inactive_path_bitmap
        pred.update_path_bmp = 1
        flags.upd_inactive_path_bmp = 1
```

When `cwnd` drops to zero, the path is moved to `inactive_path_bitmap` in SQCB1 (via S6 `update_path_bmp` action).

### 3.5 NAK Processing (S3)

**ACK type decode**:

```
ack_type = saeth.ack_status[7:5]
nak_code = saeth.ack_status[4:0]
```

| `ack_type` | Meaning |
|------------|---------|
| `000` (AETH_CODE_ACK) | Normal ACK |
| `001` (AETH_CODE_BRNR) | RNR NAK |
| `011` (AETH_CODE_NAK) | Negative ACK (error) |

**RNR NAK (BRNR)**:

```
if (ack_type == AETH_CODE_BRNR):
    if (rnr_timeout == INVALID && brnr_bitmap[7:0] != 0):
        rnr_timeout = saeth.ack_status[4:0]  // 5-bit RNR timer code
        last_ack_or_pkt_sent_ts = current_time
    flags.rnr = 1
    
    // Update rnr_retx_bmap if bitmap advanced
    if (brnr_bitmap[7:0] > rnr_retx_bmap):
        if (cumulative_fsn + 1 == snd_una):
            rnr_retx_bmap = brnr_bitmap[7:0]
```

The 5-bit RNR timer code encodes backoff from 0 µs to 163.84 ms.

**Error NAK (ACC_ERR / OP_ERR / PATHID_UNS)**:

```
if (ack_type == AETH_CODE_NAK):
    switch (nak_code):
        NAK_CODE_ACC_ERR:    req_rx_remote_access_error()
        NAK_CODE_OP_ERR:     req_rx_remote_operation_error()
        NAK_CODE_PATHID_UNS: req_rx_remote_operation_error()
```

Both error handlers:
1. Set `comp.err_disable_qp = 1`
2. Post error CQE to send CQ
3. Set QP state to `RDMA_QP_STATE_ERR` in S7
4. Set `flags.old_ack = 1` to prevent S5 from advancing `ack_msn`

### 3.6 Path Bitmap Management

**Path activation/inactivation** (via `update_path_bmp` in S6):

| Condition | Action |
|---|---|
| `cwnd <= 0` (S3) | Move to `inactive_path_bitmap` |
| `outstanding_pkts <= (cwnd >> 1)` (TX) | Move to `path_bitmap` |
| `snd_nxt == snd_una` (TX) | Move to `path_bitmap` |

The shared `path_bmp.p4` pipeline reads SQCB1 and updates:
- `path_bitmap`: 96-bit bitmap of active paths (TX schedules only from these)
- `inactive_path_bitmap`: paths whose `cwnd` dropped to zero
- `num_inactive_path`: count of inactive paths

### 3.7 MSN Completion (S5)

**ack_msn advancement** (SQCB2):

```
if (saeth.cdmsn >= ack_msn):
    new_completions = true
    ack_msn = saeth.cdmsn
    
    // Post send completion CQE
    comp.cqe.info.send.msn = ack_msn
    comp.cqe.type = RDMA_CQE_TYPE_SEND_MSN
    pred.cq = 1
```

`cdmsn` (cumulative delivered MSN) is the responder's `bmsn`. When it advances, the requester can post send completion CQEs.

---

## 4. Predicate Vector and Stage Skipping

The pipeline uses `p4_rxdma_intr.stage_skip` (one bit per stage) to prune processing early. For predicate allocation across TX and RX pipelines, grep `pred\.` and `stage_skip` across `tx/` and `rx/` stage files:

| Condition | stage_skip value | Effect |
|---|---|---|
| QP state < RTR | `0xff` | Drop; skip all stages |
| Invalid path_id | `0x2d` (S1, S3, S4, S6) | Skip S1, S3, S4, S6; allow S2, S5 (NAK gen) |
| PAWS drop (stale ACK) | `0x7f` | Skip all except S7 stats |
| Invalid fsn_una_shift | `0x7f` | Skip all remaining stages |

**Key flags**:

| Flag | Set in stage | Gates |
|---|---|---|
| `flags.rnr` | S0/S1/S2 | S3 returns early; S4 skips DMA; S5 sends RNR ACK |
| `flags.dup` | S2 | S3 skips delivery; S4 skips DMA |
| `flags.msn_completed` | S3 | S5 advances bmsn/msn_bitmap; triggers CDMSN update |
| `flags.completion_needed` | S3 | S5 posts rcq_csn DMA and sets pred.cq |
| `flags.resp_rx_gen_ack` | S2 | S5 calls ACK generation logic |
| `flags.incr_pwnd` | S2 | S3 increments path CWND |
| `pred.rqwqe` | S0 | Gates RQWQE VA2PA in S2 (SEND only) |
| `pred.rqsge0` | S0/S2 | Gates SGE0 VA2PA in S4 |
| `pred.cq` | S3 | Gates rdma_comp pipeline (CQE posting) |
| `pred.congestion_mgmt` | S0 | Gates CC update in S2 |

---

## 5. TX vs RX Asymmetry

The TX pipeline is a **producer** pipeline: it reads from host memory (SQ work requests, scatter-gather buffers) and produces packets. DMA direction is **host-to-network** (mem2pkt, phv2pkt).

The RX pipeline is a **consumer** pipeline: it receives packets from the wire and writes payload into host memory. DMA direction is **network-to-host** (pkt2mem).

**Key differences**:

| Aspect | TX Pipeline | RX Pipeline |
|---|---|---|
| **FSN tracking** | snd.una, snd.nxt, snd.cur | rcv_nxt, max_fsn, fsn_bitmap |
| **MSN tracking** | TX does not track MSN | MSN context (pkt_count), msn_bitmap (bmsn) |
| **VA2PA** | Resolve source PAs from SQ SGE list | Resolve dest PAs from RETH or RQWQE SGE list |
| **DMA direction** | mem2pkt (host → wire) | pkt2mem (wire → host) |
| **ACK generation** | resp_tx builds SAETH from path_cb0 | resp_rx populates ack_info in path_cb1, rings doorbell |
| **CC update** | TX consumes qp_cwnd_whole | RX updates qp_cwnd_whole based on ACKs |
| **Retransmission** | TX reads fsn_bitmap, snd_inflate | RX populates fsn_bitmap, snd_inflate |

A secondary asymmetry: the RX pipeline generates **outgoing** control packets (ACKs/NAKs) by writing `ack_info` to `path_cb1` and ringing a doorbell — these cause the `resp_tx` pipeline to be scheduled. The RX pipeline does not directly construct or emit ACK packets.

For cross-pipeline field interactions (which pipeline writes a field, which reads it, in which direction), grep the field name across `tx/`, `rx/`, and `include/` — single-source-of-truth ownership comments live next to each field declaration in the CB headers.

---

## 6. Stage Responsibility Summary

| Stage | Data Path | ACK Path | Shared Actions |
|---|---|---|---|
| **S0** | RQCB0: state check, path_cb_addr, VA2PA setup | SQCB0: state check, CC params, path_cb_addr | Drop if state invalid |
| **S1** | RQCB1: RNR check, MSN alloc | path_cb3: PAWS, snd.una, FSN bitmap, SACK retx doorbell | Path-level RTT (preliminary) |
| **S2** | path_cb1: FSN validation, ACK info, RQWQE VA2PA | SQCB1: CC (AIMD/RCN), qp_cwnd update, rtt_qp | ECN detection |
| **S3** | MSN context: pkt_count tracking, CQE setup | path_cb2: NAK handling, RTO, path CWND update, retx_ci | Bootstrap credit sync |
| **S4** | VA2PA probe response, payload DMA (wire→host) | (skipped) | Memory protection |
| **S5** | MSN bitmap, rcq_csn DMA, ACK gen, active QP | SQCB2: ack_msn, send CQE | Path bitmap update (S6) |
| **S6** | rdma_comp: CQE to RQ's CQ | rdma_comp: CQE to SQ's CQ | EQ notification if armed |
| **S7** | RQCB2 stats, LIF stats | SQCB4 stats, path_rx_stats | QP error state update |

---

## 7. Completion Generation (rdma_comp Pipeline)

The `rdma_comp` pipeline runs as a separate P4+ program, dispatched when `pred.cq == 1`. It executes two tables:

**S6: `rdma_comp_cqcb_tbl`**:
- Reads `rdma_cqcb0_t`
- Consumes a CQ entry slot: `proxy_pindex++`
- Toggles `color` on ring wrap
- If CQ was armed: trigger notification (`pred.notif = 1`)

**S7: `rdma_comp_cqe_tbl`**:
- Resolves CQE physical address via VA2PA
- Emits `phv2mem` DMA command to write CQE
- For RCCL paths: split CQE into two 16-byte DMAs with `DMA_FENCE_FENCE` on second half

**EQ Notification** (`rdma_comp_eqcb_tbl`):
- Fires when `pred.notif == 1` (CQ was armed)
- Posts EQE to event queue
- Optionally asserts interrupt if `int_enabled`

---

## 8. PAWS and Stale ACK Protection

The PAWS (Protection Against Wrapped Sequence) check in S1 guards against ancient ACKs:

```
rtt_ticks = current_time - echo_ts
if (current_rtt != 0):
    max_rtt = min(64 * current_rtt, ECHO_TS_MAX_ECHO_TS)
    if (rtt_ticks > max_rtt):
        flags.ack_paws_drop = 1
        drop = 1
        stage_skip = 0x7f  // skip all except stats
```

Any ACK older than 64× the smoothed RTT is dropped. This prevents spurious CC reactions to reordered or delayed ACKs.

---

## Appendix: Related Documentation

- **01-protocol.md**: Protocol definitions, header formats (BTH, METH, SAETH, RETH), SACK/RTO/AIMD algorithm spec
- **02-tx-pipeline.md**: TX-side counterpart to this doc
- **CB headers** (`include/rdma_sqcb.p4`, `rdma_rqcb.p4`, `path_cb.p4`, `rdma_cqcb.p4`): Field tables with stage ownership comments
- **PHV defs** (`tx/meta_roce_tx_phv.p4`, `rx/meta_roce_rx_phv.p4`): PHV layouts
