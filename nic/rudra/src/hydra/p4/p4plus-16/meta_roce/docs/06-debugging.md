# Meta RoCE Debugging Guide

Comprehensive debugging reference for Meta RoCE (RDMA) issues in the Hydra pipeline.

**For CB field offsets, bit layouts, and exact constant values**, read the
CB headers directly: `include/rdma_sqcb.p4`, `rdma_rqcb.p4`, `path_cb.p4`,
`rdma_cqcb.p4`, and the constants in `include/meta_roce_defines.{p4,h}`.

---

# Part 1: Reference

## Complete nicctl RDMA Command Reference

### Command Tree

```
nicctl show rdma
├── queue-pair [--queue-pair-id N] [--lif UUID] [--lif-hw-id N]
│   │          [--src-ip IP] [--dst-ip IP] [--error-disabled]
│   │          [--state all|reset|error|active|in-progress]
│   │          [--used] [--rccl-data] [--rccl-cts]
│   │          [--status] [--summary] [--raw] [--detail] [-j]
│   ├── path [--path-id N] [--queue-pair-id N] [--lif UUID]
│   │   │     [--status] [--raw] [-j]
│   │   └── statistics [--queue-pair-id N] [--path-id N] [--drop] [-j]
│   └── traffic-profile [--profile-id N] [-j]
├── congestion-control
│   └── profile [--profile-id N] [-j]
├── path [--profile-id N] [-j]
└── statistics [-c UUID] [-j]

nicctl show pipeline internal rdma
├── (default — CC profile + path params per card. On older firmware this is
│    the only way to view CC profile; newer firmware uses
│    nicctl show rdma congestion-control profile)
└── anomalies [--lif UUID] [--lif-hw-id N]

nicctl update rdma
├── path --profile-id N [--count] [--minimum-rto] [--rtt-bucket-size]
│        [--sack-retx-mode immediate|window-delay|disable]
│        [--rto-inactivate-count 1-7]
└── congestion-control
    └── profile --profile-id N [--disable] [--rcn enable|disable]
                [--epsilon] [--beta] [--lambda] [--gamma] [--omega]
                [--fast-start-burst] [--round-robin-burst]
                [--qwnd-min] [--rcn-pwnd-min] [--pwnd-max-shift]
```

### Flag Behavior

| Flag | What it does |
|------|-------------|
| `--status` | Human-readable operational status — CC state, CWND, paths, ring PI/CI, retransmit state |
| `--raw` | Full CB field dump (sqcb0-4, rqcb0-3, pathcb0-3) — every field with hex values |
| `--detail` | Extended connection summary |
| `--summary` | Quick count: total QPs, RCCL CTS/data QP counts |
| `-j/--json` | JSON of `--status`/default view — NOT raw CB fields. For scripting. |
| `--used` | Only QPs that have been used (non-zero traffic) |
| `--rccl-data` | Only RCCL data QPs (carrying collective traffic) |
| `--rccl-cts` | Only RCCL control QPs |
| `--state STATE` | Filter by state: reset, error, active, in-progress (comma-separated) |
| `--error-disabled` | Filter for error-disabled QPs |
| `--drop` | (path statistics only) Shows only drop counters |
| `--path-id N` | Single path filter (requires `--queue-pair-id` + `--lif`) |
| `-c UUID` | Scope to specific card (persistent, inherited by subcommands) |

### Diagnostic Command Quick Reference

```bash
# 1. ALWAYS START HERE — anomalies across all cards
sudo nicctl show pipeline internal rdma anomalies

# 2. QP summary — quick count
sudo nicctl show rdma queue-pair --summary -c <card-uuid>

# 3. QP status — CC state, CWND, active paths, rate hints
sudo nicctl show rdma queue-pair --used --status -c <card-uuid>
sudo nicctl show rdma queue-pair --rccl-data --status -c <card-uuid>

# 4. Path status — per-path retransmit state, ring PI/CI, cwnd
sudo nicctl show rdma queue-pair path --status --queue-pair-id <N> --lif <uuid>

# 5. Path statistics — TX/RX counters, CC add_incr/mul_decr, RTT histogram
sudo nicctl show rdma queue-pair path statistics --queue-pair-id <N> --lif <uuid>

# 6. CC profile — current congestion control parameters
# Newer firmware:
sudo nicctl show rdma congestion-control profile -j
sudo nicctl show rdma path -j
# Older firmware (if above commands not available):
sudo nicctl show pipeline internal rdma

# 8. Raw CB dump (only when --status doesn't have the field you need)
sudo nicctl show rdma queue-pair --raw --queue-pair-id <N> --lif <uuid>
sudo nicctl show rdma queue-pair path --raw --queue-pair-id <N> --lif <uuid>
```

## Pre-Flight Checks

Before diving into QP-level debugging, verify the NIC is healthy:

```bash
sudo nicctl show card                                    # heartbeat, coredump, card state
sudo nicctl show port -c <card-uuid>                     # link up/down, FEC errors, speed
lspci -s <bdf> -vvv | grep LnkSta                       # PCIe gen/width
sudo nicctl show pipeline internal anomalies             # non-RDMA pipeline anomalies
sudo nicctl show pipeline internal rdma anomalies        # RDMA-specific anomalies
```

## Known Benign Conditions

| Condition | Why it's benign |
|-----------|----------------|
| `opcode 2 error 5: "Couldn't create ib_mad QP1"` | Expected on bootup — UD QP unsupported in Hydra |
| `spec_failure` toggling during traffic | Normal speculation — automatic rollback and retry |
| `ooo_packets > 0` with multipath | Expected — packets arrive out of order across paths |
| `cwnd_retry` cycling during traffic | Normal CC — window fills, drains, refills |
| `nak_prune=1` with OOO traffic | By design — first OOR triggers NAK, rest silently dropped |
| At line rate: TXS XOFF ~96-97%, drops ~20-27M/s | Normal flow control under back-pressure |

## How to Pick a QP for Debugging

### Quick count first
```bash
sudo nicctl show rdma queue-pair --summary -c <card-uuid>
```

### For IB tests (ib_write_bw, ib_write_lat, etc.)
```bash
# Any used QP works — IB tests create simple QP pairs
sudo nicctl show rdma queue-pair --used --status -c <card-uuid>
```

### For RCCL tests
```bash
# Pick a data QP that has carried traffic
# IMPORTANT: use --used, not --state active. RCCL traffic is bursty —
# QPs momentarily show RTS (idle) between collective operations.
# --state active may miss them; --used catches any QP with non-zero counters.
sudo nicctl show rdma queue-pair --rccl-data --used --status -c <card-uuid>
```

### Finding an outlier in many QPs
```bash
# Scan all used QPs — look for low CWND or high unacked messages
sudo nicctl show rdma queue-pair --used --status -c <card-uuid>
```

| Field from QP `--status` | Healthy | Outlier |
|---|---|---|
| `QP CWND (whole)` | Similar across QPs | Much lower than others |
| `Unacked messages` | 0-2 | Large gap |
| `Active paths` | Close to max_paths | 0 or much fewer |
| `Congestion state` | `aimd` | `fast_start` (stuck) |

## Identifying NICs

```bash
sudo nicctl show card                    # List all cards with BDFs and UUIDs
ibv_devinfo -l                           # List RDMA devices
```

**Identifiers:** BDF (06:00), device name (benic1, roce_benic1p1), port number (1-8).

## CB Fields: Advancing vs Stuck

During active traffic, certain fields should be advancing (take 2 samples ~100ms apart).

| Field | Where | Means |
|-------|-------|-------|
| `sqcb2.ack_msn` | QP `--status` → ACK MSN | Messages being acknowledged |
| `pathcb2.snd_una` | Path `--status` → snd_una | Packets being acknowledged per-path |
| `pathcb2.snd_nxt` | Path `--status` → snd_nxt | New packets being sent |
| `pathcb1.rcv_nxt` | Path `--status` → rcv_nxt | Packets received in-order |
| `pathcb1.max_fsn` | Path `--status` → max_fsn | Any packets arriving (even OOO) |

| Field frozen | Means |
|-------------|-------|
| `snd_una` not moving | ACKs not arriving from peer |
| `snd_nxt` not moving | Not sending (cwnd=0, all paths inactive, spec_failure loop) |
| `rcv_nxt` frozen, `max_fsn` advancing | Gaps not filling (packet loss) |
| Both frozen | No traffic arriving |
| `ack_msn` not moving | Message-level ACKs stuck |

## Error Code Reference

### NAK and ACK Status Codes

| Ack Status [7:5] | Ack Status [4:0] | Syndrome | Meaning | Recovery |
|------------------|------------------|----------|---------|----------|
| `000` | `00000` | ACK | All data in-order | None |
| `000` | `00001` | SACK | Out-of-order; FSN bitmap follows | Retransmit missing FSNs |
| `001` | TTTTT | HRNR | Hardware not ready | Wait and retry |
| `010` | TTTTT | BRNR | Buffer not ready (RWQE missing) | FSN migration; retry |
| `011` | `00000` | NAK-PathID | Path ID unsupported | Check path config |
| `011` | `00001` | NAK-AccErr | Remote access error | Check R-Key, VA, access flags |
| `011` | `00010` | NAK-InvReq | Invalid request | Check opcode, format |
| `011` | `00011` | NAK-OpErr | Operational error | Check QP state |

**RNR backoff encoding (TTTTT):** `00000` = 0µs; `0xxxx` (N=1–15) = 5µs × 2^N.

## Opcode Quick Reference

| Hex | Name | Additional Headers |
|-----|------|--------------------|
| 0xC0 | Send | METH + Payload |
| 0xC1 | Send with Immediate (last) | METH + ImmDt + Payload |
| 0xC2 | RDMA Write with Immediate (last) | METH + RETH + ImmDt + Payload |
| 0xC6 | RDMA Write | METH + RETH + Payload |
| 0xC7 | RDMA Write with Immediate (non-last) | METH + RETH + Payload |
| 0xCC | RDMA Read Request | METH + RETH |
| 0xCD | RDMA Read Request with Immediate | METH + RETH + ImmDt |
| 0xCF | RDMA Read Response | METH + Payload |
| 0xD0 | RNR-Cancel | RNR-Cancel header |
| 0xD1 | Selective ACK | SAETH + optional bitmaps |
| 0xD2 | Atomic Ack | METH + AtomicAckETH |
| 0xD4 | FetchAdd | METH + AtomicETH |
| 0xD5 | CmpSwap | METH + AtomicETH |
| 0xDE | Reliable Control | METH + Control + Payload |
| 0xDF | Unreliable Control (Echo/Ping) | Control + Payload |

**Transport type bits [7:5] = `110`**. **UDP destination port: 2766**

## Reading Paths (pointers to other docs)

| Goal | Read |
|------|------|
| New to Meta RoCE | `00-overview.md` → `01-protocol.md` → `02-tx-pipeline.md` |
| TX stall or dropped packet | `02-tx-pipeline.md` (sections 1-2, 5, 3) |
| Congestion control algorithm | `01-protocol.md` (sections 6.1–6.4) → `02-tx-pipeline.md` (section 5) |
| RX delivery issues | `03-rx-pipeline.md` (sections 1-2) |
| Retransmission | `02-tx-pipeline.md` (section 3) → `03-rx-pipeline.md` (section 3) |
| QP setup/debugging | `04-controlplane.md` |
| Multipath / path selection | `02-tx-pipeline.md` (section 5) |
| Performance (asicmon) | `10-performance-debugging.md` |

---

# Part 2: Correctness Debugging

## Anomaly Decision Tree

### Overview: 4-Step Workflow

```
Step 1: Run anomalies on BOTH sides (sender + receiver)
Step 2: Classify the stuck type from anomaly output
Step 3: Drill into QP/path state with --status and --raw
Step 4: Identify root cause and take action
```

### Sender-Side SQ Anomalies

| Anomaly Message | Root Cause | Drill-Down | Next Action |
|----------------|-----------|------------|-------------|
| `"queue is in erroneous state"` | QP hit fatal error | `--raw` → sqcb3/sqcb4 err_dis bits | See QP Error-Disabled section |
| `"requester TX error-disabled: 0xN"` | TX pipeline error | `--raw` → sqcb3 bits | See QP Error-Disabled section |
| `"requester RX error-disabled: 0xN"` | Remote NAK error | `--raw` → sqcb4 bits | See QP Error-Disabled section |
| `"SQ ring pi != ci (WQEs pending)"` | WQEs not processed | `--status` → Queue state | If not RTS, QP not ready |
| `"spec_failure active"` | S2 speculation mismatch | `--status` → Active paths | **Automatic recovery**. If stuck, check path_bitmap=0 |
| `"all paths inactive"` | Every path RTO'd | `--status` → Active/Inactive paths | Check bootstrap_in_progress. **Cross-node:** check peer RQ |
| `"inactive path bitmap mismatch"` | Consistency error | `--raw` | Firmware bug — collect techsupport |
| `"QP cwnd != total paths cwnd"` | CC accounting drift | `--status` + path `--status` | Collect techsupport |
| `"ack_msn not advancing"` | Messages not ACK'd | `--status` → Unacked messages | **Cross-node:** check peer |
| `"active drops detected"` | Packets being dropped | `--raw` → sqcb3/sqcb4 counters | Check if growing fast |
| `"invalid paths"` | Path ID out of range | `--raw` | Check path configuration |
| `"VA-to-PA translation errors"` | MR issue | `--raw` | Check MR registration |

### Sender-Side Path TX Anomalies

| Anomaly Message | Root Cause | Drill-Down | Next Action |
|----------------|-----------|------------|-------------|
| `"fatal error: retransmit ring full"` | **FATAL** — no P4 recovery | Path `--raw` → fatal_err_retx_full | QP must be destroyed. Collect techsupport |
| `"retx stuck - cause: sack pwnd-delay gate (cwnd=0)"` | CC collapsed | Path `--status` → cwnd=0 | Check ECN, CC profile. See CC Debugging section |
| `"retx stuck - cause: scheduler not dispatching"` | Scheduler issue | Path `--status` → ring PI/CI | Check asicmon TXS |
| `"retx active but ACKs not arriving"` | Peer not ACKing | Path `--status` → snd_una frozen | **Cross-node:** check peer path RX |
| `"cwnd_retry stuck"` | Window exhausted | Path `--status` → cwnd, outstanding | Check peer ACK path |
| `"timer_started but no timer event"` | Loss detection broken | Path `--raw` | **Firmware bug** — techsupport |
| `"packets outstanding but timer not started"` | Loss detection broken | Path `--raw` | **Firmware bug** — techsupport |
| `"retx ring mismatch"` | Consistency error | Path `--raw` | **Firmware bug** — techsupport |

### Receiver-Side Path RX Anomalies

| Anomaly Message | Root Cause | Drill-Down | Next Action |
|----------------|-----------|------------|-------------|
| `"ack ring stuck - data arriving but ACKs not sent"` | Scheduler issue | Path `--status` → Ring0 ack PI/CI | Check asicmon TXS |
| `"receiver gap growing"` | Packet loss on network | Path `--status` → rcv_nxt, max_fsn | Check switch FEC, PFC |
| `"receiver stalled - nak_prune=1"` | Sender FSNs outside window | Path `--raw` → nak_prune | Sender retransmitting stale FSNs |
| `"ACK generation broken"` | No ACK queued despite data | Path `--raw` | **Firmware bug** — techsupport |

### Receiver-Side RQ Anomalies

| Anomaly Message | Root Cause | Drill-Down | Next Action |
|----------------|-----------|------------|-------------|
| `"queue is in erroneous state"` | RQCB0 in ERR | `--raw` → rqcb2 err_dis bits | See QP Error-Disabled section |
| `"responder RX error-disabled"` | Error disabled | `--raw` → rqcb2 bits | See QP Error-Disabled section |
| `"active drops"` | Actively dropping | `--raw` → rqcb2 counters | Identify which counter growing |
| `"msn_bitmap non-zero"` | Completions pending | `--raw` → rqcb1.msn_bitmap | If stuck after traffic, check CQ |

## Stuck Test Debugging Workflow

When a test hangs or traffic stops flowing, follow this end-to-end workflow.

### Phase 1: Sender SQ — What's stuck?

```bash
sudo nicctl show pipeline internal rdma anomalies
sudo nicctl show rdma queue-pair --used --status -c <card-uuid>
```

**Check in QP `--status`:**

| Field | Healthy | Stuck |
|-------|---------|-------|
| SQ ring PI/CI | PI == CI | PI != CI (WQEs pending) |
| ACK MSN vs BMSN | Close | Gap = unacked messages |
| Active paths | > 0 | 0 (all inactive) |
| Congestion state | `aimd` | `fast_start` (stuck) |

### Phase 2: Sender Paths — Which paths have pending work?

```bash
sudo nicctl show rdma queue-pair path --status --queue-pair-id <N> --lif <uuid>
```

| Field | Healthy | Stuck |
|-------|---------|-------|
| snd_una == snd_nxt | Equal (idle) or close | Gap = outstanding unacked |
| Retransmit state | (none) | `cwnd_retry` or `rto_retransmit` |
| CWND retry in progress | False | True |
| Path disabled (cwnd) | False | True |
| fatal_err_retx_full | (not shown) | Use `--raw` to check |

### Phase 3: SSH to Responder — Is data arriving?

```bash
# Take 2 samples ~1s apart
sudo nicctl show rdma queue-pair path statistics --queue-pair-id <N> --lif <uuid>
```

- **RX packets advancing** → data arriving → Phase 4
- **RX packets frozen** → check link, switch FEC, PFC

### Phase 4: Responder — Are packets being dropped?

```bash
sudo nicctl show rdma queue-pair --raw --queue-pair-id <N> --lif <uuid>
```

| Counter growing | Root cause | Action |
|----------------|-----------|--------|
| `rqcb2.num_fsn_oor` | FSN outside window | Sender retransmitting stale FSNs |
| `rqcb2.num_dup` | Duplicate packets | Usually benign during recovery |
| `rqcb2.num_rx_rnr` | No RWQE posted | App-side issue |
| `rqcb2.num_drop` | General drops | Check err_dis bits |
| All zero | No drops | Go to Phase 5 |

### Phase 5: Responder RQ — Are completions stuck?

- `rqcb1.msn_bitmap` non-zero = messages received but not completed
- Check CQ: `pi != ci` → app not consuming CQEs

### Phase 6: Responder Path — FSN holes?

| Condition | Interpretation | Action |
|-----------|---------------|--------|
| `fsn_bitmap` non-zero, `rcv_nxt` advancing | Normal OOO recovery | Wait |
| `fsn_bitmap` non-zero, `rcv_nxt` frozen, `max_fsn` advancing | Gaps not filling | Check sender retx |
| Both frozen | Fully stalled | Check sender |
| `nak_prune = 1` persistent | OOR packets dropped | Sender FSNs outside window |

### Phase 7: Responder Path — ACKs going out?

| Condition | Interpretation | Action |
|-----------|---------------|--------|
| `pi_ack == ci_ack`, data received | No ACKs queued | Firmware bug if rcv_nxt != max_fsn |
| `pi_ack != ci_ack`, `ci_ack` advancing | ACKs being sent | Not stuck |
| `pi_ack != ci_ack`, `ci_ack` frozen | ACK ring stuck | Scheduler issue |

### Quick Decision Flow

```
Sender SQ pi != ci?
  YES → Check path --status
    ├── snd_una frozen? → SSH to responder
    │     ├── RX packets arriving? YES → drops? → identify type
    │     │                        NO  → network loss
    │     └── msn_bitmap? → CQ issue
    │         fsn holes? → sender not retransmitting
    │         ack ring stuck? → scheduler
    ├── snd_nxt frozen? → cwnd=0 or all paths inactive
    └── fatal_err_retx_full? → QP dead
  NO  → QP idle or app not posting work
```

## QP Error-Disabled Debugging

### Identify which side

```bash
sudo nicctl show rdma queue-pair --state error -c <card-uuid>
sudo nicctl show rdma queue-pair --error-disabled -c <card-uuid>
```

### Requester TX Error-Disabled (sqcb3 bits)

| Bit | Field | Meaning | Likely cause |
|-----|-------|---------|-------------|
| 0 | `qp_err_dis_lkey_inv_pd` | Local key PD mismatch | MR in different PD than QP |
| 1 | `qp_err_dis_lkey_rsvd_lkey` | Reserved local key | key=0 |
| 2 | `qp_err_dis_lkey_access_violation` | Local key access violation | MR missing permission |
| 3 | `qp_err_dis_table_error` | Table lookup error | Key/page table failed |
| 4 | `qp_err_dis_va_no_page` | VA has no page | VA not backed by physical page |
| 5 | `qp_err_dis_inv_wqe_format` | Invalid WQE format | Malformed WQE |
| 6 | `qp_err_dis_inv_wqe_len` | Invalid WQE length | Size mismatch |

### Requester RX Error-Disabled (sqcb4 bits)

| Bit | Field | Meaning | Likely cause |
|-----|-------|---------|-------------|
| 0 | `qp_err_dis_remote_inv_req_err` | Remote invalid request | Malformed request |
| 1 | `qp_err_dis_remote_acc_err` | Remote access error | Check responder rqcb2 for specific MR error |
| 2 | `qp_err_dis_remote_oper_err` | Remote operational error | Responder internal error |

### Responder RX Error-Disabled (rqcb2 bits)

| Bit | Field | Meaning | Likely cause |
|-----|-------|---------|-------------|
| 0 | `qp_err_dis_access_err` | Access error | MR access violation |
| 1 | `qp_err_dis_dma_len_err` | DMA length error | Payload exceeds MR bounds |
| 2 | `qp_err_dis_insuff_sge_err` | Insufficient SGE | Not enough scatter-gather entries |
| 3 | `qp_err_dis_rsvd_key_err` | Reserved key | R-Key=0 |
| 4 | `qp_err_dis_key_state_err` | Key state error | MR freed or not registered |
| 5 | `qp_err_dis_key_pd_mismatch` | Key PD mismatch | MR and QP in different PDs |
| 6 | `qp_err_dis_key_acc_ctrl_err` | Key access control | MR missing REMOTE_WRITE/READ |
| 7 | `qp_err_dis_user_key_err` | User key error | App key validation failed |
| 8 | `qp_err_dis_key_va_err` | Key VA error | VA outside MR range |
| 9 | `qp_err_dis_type2a_mw_qp_mismatch_err` | MW QP mismatch | Memory window wrong QP |
| 10 | `qp_err_dis_invalid_wqe_format_err` | Invalid WQE format | Receive WQE malformed |
| 11 | `qp_err_dis_invalid_max_sge_err` | Invalid max SGE | SGE count exceeds max |

**Common patterns:**
- Bit 6 (`key_acc_ctrl_err`) → MR missing IBV_ACCESS_REMOTE_WRITE
- Bit 8 (`key_va_err`) → sender VA outside responder MR range
- sqcb4 bit 1 → always cross-check responder rqcb2 for specific error

**Recovery:** QP modify to RST → RTS, or destroy/recreate. For `fatal_err_retx_full`: must destroy.

## Multi-Port Correctness Debugging

For multiplane topologies (`num_ports > 1`). For path selection and port bitmap concepts,
see `02-tx-pipeline.md` section 5.

### Port Bitmap Intersection Check

All four bitmaps must be non-zero for a port to be eligible:

```
active_port_bitmap = active_lport_bitmap
                   & active_rport_bitmap
                   & header_template_port_bitmap
                   & nonzero_path_port_bitmap
```

```bash
sudo nicctl show rdma queue-pair --raw --queue-pair-id <N> --lif <uuid>
# Check SQCB1: active_rport_bitmap, header_template_port_bitmap,
#              nonzero_path_port_bitmap, num_ports
```

| Bitmap zero | Means | Fix |
|-------------|-------|-----|
| `header_template_port_bitmap` | Port not configured by nicmgr | QP setup issue — check control plane |
| `active_rport_bitmap` | Responder not advertising this port via SAETH | Check responder port state, check if ACKs are flowing |
| `nonzero_path_port_bitmap` | All paths on this port have cwnd=0 | CC-driven port loss — see below |
| `active_lport_bitmap` | Local port link down | Check `nicctl show port` |

### nonzero_path_port_bitmap Going to Zero

When ALL paths on a port have cwnd=0 → that port's bit clears in `nonzero_path_port_bitmap`
→ port removed from `active_port_bitmap` → NO path on that port can be selected.

Bootstrap can't activate paths on that port because the port is filtered out before path selection.
This is a **CC-driven port loss** — different from link-down or force_inactivate.

**Detection (take 2-3 samples):**
```bash
# QP --raw: check nonzero_path_port_bitmap across samples
# Path --status: check cwnd per path, group by port
```

**Recovery:** Requires cwnd to grow back > 0 on at least one path on that port (via AI from ACKs).
If no ACKs arrive (port is dead), manual intervention or QP reset needed.

### force_inactivate / Port-Down Failover

Two triggers set `force_inactivate = 1` on a path (TX S3):
1. **RTO failover:** `rto_retx_snd_una_count` reaches `rto_inactivate_count` (default 3)
2. **Port-down:** `active_lport_bitmap` has this port's bit clear while other ports are up

**Check per-path state:**
```bash
sudo nicctl show rdma queue-pair path --raw --queue-pair-id <N> --lif <uuid>
# Look at: pathcb2.force_inactivate, pathcb3.force_inactivate_flags
```

| force_inactivate | flags | snd_una vs snd_nxt | Meaning |
|-----------------|-------|-------------------|---------|
| 0 | 0x0 | any | Normal — no failover |
| 1 | 0x3 | snd_una < snd_nxt | Freshly force-inactivated; qp_cwnd will be decremented |
| 1 | 0x1 | snd_una < snd_nxt | qp_cwnd decremented; waiting for ACKs to drain |
| 1 | 0x1 | snd_una == snd_nxt | **Stuck** — all ACKs received but recovery not clearing |
| 0 | 0x0 | — | Recovered — path reset to inactive_path_bitmap for re-bootstrap |

**Stuck force_inactivate:** If `snd_una == snd_nxt` but `force_inactivate` still 1, check
`pathcb2.cwnd_retry` — recovery requires `cwnd_retry == 0`.

### Both path_bitmap and inactive_path_bitmap Zero

This is a fatal state — no path exists in any state. Four code paths can cause this:

1. **Fatal retx ring full** on all paths — path removed from path_bitmap but never added to inactive
2. **Bootstrap with cwnd ≤ 0** — path not promoted, subsequent congestion removes it from inactive
3. **Congestion collapse** — all paths cwnd→0, bootstrap attempts fail
4. **force_inactivate recovery with cwnd=0** — path moved to inactive but never bootstraps back

**Detection:**
```bash
# QP --raw: sqcb1.path_bitmap_0/1 AND sqcb1.inactive_path_bitmap_0/1 both zero
# Check: pathcb2.fatal_err_retx_full on each path
```

### Path Distribution Across Ports

In a healthy multiplane setup, active paths should be evenly distributed across ports.

```
max_paths_per_port = ceil(max_paths / num_ports)
Port N active paths = popcount(path_bitmap >> (N × max_paths_per_port) & mask)
```

| Distribution | Meaning |
|---|---|
| Equal across ports | Healthy multiplane load balancing |
| One port has 0 active paths | All paths on that port force_inactivated or cwnd=0 |
| One port has far fewer | Partial imbalance — some paths removed on that port |
| All ports zero | path_bitmap == 0 — see "both bitmaps zero" above |

---

# Part 3: Performance Debugging

## Sampling Methodology

Traffic can be bursty — a single sample may catch a peak or trough. Always take **2-3 samples** spaced a few seconds apart for any metric:

- **asicmon -P**: Run 2-3 times, compare wire BW across runs. If variance > 10%, traffic is bursty — use the average.
- **Path statistics**: Take 2 samples, compute the **delta** (second - first) to see current rate, not cumulative totals.
- **QP/path --status**: Take 2 samples to see if CWND, snd_una, outstanding are changing or frozen.
- **asicmon (vanilla)**: Cumulative since boot — useful for long-term trends but not current state. Use `-P` for snapshots.

## Debugging Flow: Narrow Down the Bottleneck

```
Cluster (multi-node)
  → Compare wire BW across nodes → find the slow node
    → On the slow node: identify which card (nicctl show port / asicmon per card)
      → On the slow card: asicmon pipeline check (Phase 0)
        → On the slow card: QP/path CC check (Phase 1+)
```

For **single-NIC tests** (IB perf between two nodes): skip straight to the card you know is carrying traffic.

## Cluster-Scale Considerations

Before drilling into CC on a single QP, establish the cluster-level picture:

### Find the bottleneck node
```bash
# Compare wire bandwidth across all nodes (asicmon -P on each)
# The node with lowest throughput is the starting point
```

### Check consistency across nodes
```bash
# CC profile should be identical on all NICs
sudo nicctl show rdma congestion-control profile -j    # on each node, diff outputs

# Firmware version should match
sudo nicctl show version                                # on each node

# QP CWND comparison — find the outlier
sudo nicctl show rdma queue-pair --used --status -c <card-uuid>   # on each node
# Compare QP CWND (whole) across nodes — low outlier is the problem
```

### Path statistics comparison
- Compare `CC multiplicative decrements` across nodes — highest = most congestion
- Compare `CNP received` — uneven means switch ECN threshold differs per port
- Compare `RTO retransmit packets` — high on one node = link/switch issue

### Switch-side checks
When cross-node comparison points to network:
- FEC errors on sender/receiver switch ports
- PFC pause frame counters
- Port TX/RX drop counters
- ECN/WRED threshold configuration

### RCCL ring topology
- One slow node blocks entire ring
- Find weakest link: node with lowest CWND or highest retransmission

## CC Performance Debugging — Single Port, No RCN

**Scope:** CC enabled (`congestion_mgmt=1`), RCN disabled (`rcn=0`), single port (`num_ports=1`).

For CC algorithm details, see `01-protocol.md` sections 6.1-6.2.
For path selection and bootstrap, see `02-tx-pipeline.md` section 5.
For asicmon usage and pipeline-level bottleneck analysis, see `10-performance-debugging.md`.

### Phase 0: Confirm it's not a pipeline bottleneck (asicmon)

Before diving into CC, rule out pipeline-level issues using the workflow in `10-performance-debugging.md`:

```bash
source /etc/profile.d/amd_ainic_user_profile_update.sh

# Wire bandwidth — are we at line rate?
PAL_CARD_UUID=$CARD_UUID asicmon -P | grep -E "PBI_NET_BPS|PBE_NET_BPS"

# If below line rate: stage backpressure?
PAL_CARD_UUID=$CARD_UUID asicmon
# Look at per-stage (utl/xff/idl) — high out xoff points to downstream bottleneck

# PCIe bandwidth
PAL_CARD_UUID=$CARD_UUID asicmon -b
```

**Decision:**
- Wire BW ≥ 95% line rate → system healthy, no CC issue
- Below line rate + high stage XOFF/MPU% → pipeline bottleneck (see `10-performance-debugging.md`)
- Below line rate + S3/S4 drops high → **CC window problem** → continue to Phase 1
- Below line rate + low drops + low XOFF → application not posting enough work (check doorbell rate)

### Phase 1: Confirm the window is the bottleneck

```bash
# QP-level CC state
sudo nicctl show rdma queue-pair --used --status -c <card-uuid>
# Look at: Congestion state, QP CWND (whole), Active paths, Unacked messages

# Per-path CC stats (add_incr vs mul_decr tells the story)
sudo nicctl show rdma queue-pair path statistics --queue-pair-id <N> --lif <uuid>

# Per-path operational state
sudo nicctl show rdma queue-pair path --status --queue-pair-id <N> --lif <uuid>
```

**What to compare in QP `--status`:**

| Field | Healthy | Unhealthy |
|-------|---------|-----------|
| `Congestion state` | `aimd` | `fast_start` (stuck in startup) |
| `QP CWND (whole)` | 10-256 (depends on BDP) | 1-3 (collapsed to floor) |
| `Active paths` | Close to max_paths | 0 or few (paths inactive) |
| `Unacked messages` | 0-2 | Large gap |

**What to compare in path statistics:**

| Counter | Healthy | Unhealthy |
|---------|---------|-----------|
| `CC additive increments` | Growing steadily | Low or zero |
| `CC multiplicative decrements` | Occasional | Close to or exceeding add_incr |
| `CWND retry retransmit packets` | Low | High (window constantly exhausted) |
| `RTO retransmit packets` | Near zero | Growing (loss-based MD) |

**What to check in path `--status`:**

| Field | Healthy | Unhealthy |
|-------|---------|-----------|
| `Congestion window (effective PWND)` | 10-256 | 1-3 (collapsed) |
| `CWND retry in progress` | False | True (frequently) |
| `Path disabled (cwnd)` | False | True |

### Phase 2: Determine WHY the window is small

```
Is mul_decr >> add_incr in path stats?
├── YES → Window being hammered down
│   ├── CNP received high? → ECN-based MD
│   │   └── Switch ECN threshold too low, or genuine congestion
│   ├── RTO retransmit packets high? → Loss-based MD (lambda)
│   │   └── Packet loss on network (check switch FEC, drops)
│   └── Both high? → Combined ECN + loss
│
├── add_incr ≈ mul_decr → Window oscillating (not growing)
│   └── epsilon vs beta ratio too low — AI too slow to recover from each MD
│
└── Both low → Window not growing at all
    ├── Congestion state = fast_start? → Stuck in startup
    │   └── Check if ACKs arriving (first ACK triggers AIMD transition)
    ├── QP CWND at qwnd_min? → Floor reached, AI not effective
    │   └── Increase epsilon or qwnd_min
    └── All paths inactive? → No path can send
        └── See Stuck Test Debugging Workflow
```

### Phase 3: Check CC profile parameters

```bash
# Newer firmware:
sudo nicctl show rdma congestion-control profile -j
sudo nicctl show rdma path -j

# Older firmware (if above not available):
sudo nicctl show pipeline internal rdma
# Shows CC params per card: epsilon, beta, lambda, omega, gamma,
# fast_start_burst, round_robin_burst, qwnd_min, rcn_pwnd_min, etc.
```

| Parameter | Check | Issue if wrong |
|-----------|-------|----------------|
| `epsilon` | 1-20 | Too small → slow AI recovery |
| `beta` | 0-3 (log shift) | 0 = full window reduction per CE (too aggressive) |
| `lambda` | 0-3 (log shift) | 0 = full reduction per loss (too aggressive) |
| `qwnd_min` | 1-8 | Too small → window collapses to near-zero |
| `fast_start_burst` | 1-15 | Too small → not enough initial probing |
| `fast_start_qwnd_max_shift` | 2-15 | Too small → exits fast start too early |
| `exact_cwnd_enforce` | enable/disable | Enabled + small cwnd = constant cwnd_retry |
| `round_robin_burst` | 1-15 | 1 = path switch every packet (overhead) |
| `minimum_rto` | 20-1000µs | Too low → premature timeouts. Too high → slow recovery |
| `rto_inactivate_count` | 1-7 | Too low → paths deactivated too quickly |

### Phase 4: Check network-side ECN

If `CNP received` is high:
- Check switch ECN/WRED threshold configuration
- Compare queue depth vs marking threshold
- If threshold too low → marking at low utilization → unnecessary MD

If `RTO retransmit packets` is high:
- Check switch port drop counters
- Check FEC uncorrectable errors
- Check PFC pause frame counters

### Phase 5: Tune CC parameters

```bash
# Faster window growth (increase AI rate)
sudo nicctl update rdma congestion-control profile --profile-id 0 --epsilon 4

# Gentler MD on ECN (log_beta=2 means β=1/4 instead of β=1/2)
sudo nicctl update rdma congestion-control profile --profile-id 0 --beta 2

# Higher minimum window floor
sudo nicctl update rdma congestion-control profile --profile-id 0 --qwnd-min 4

# Larger fast start max window
sudo nicctl update rdma congestion-control profile --profile-id 0 --fast-start-qwnd-max-shift 10

# Increase RR burst (reduce path-switch overhead)
sudo nicctl update rdma congestion-control profile --profile-id 0 --round-robin-burst 4

# Increase minimum RTO (if premature timeouts)
sudo nicctl update rdma path --profile-id 0 --minimum-rto 100

# Reduce RTO sensitivity
sudo nicctl update rdma path --profile-id 0 --rto-inactivate-count 5
```

**Note:** CC profile changes apply to NEW QPs — existing QPs keep current parameters. Restart traffic after changing.

### Phase 6: Check for secondary CC issues (take 2-3 samples for each)

These apply to **both CC-only and CC+RCN**.

#### RTT health

```bash
# QP-level RTT
sudo nicctl show rdma queue-pair --used --status -c <card-uuid>
# Look at: RTT QP (us)

# Per-path RTT (take 2-3 samples)
sudo nicctl show rdma queue-pair path --status --queue-pair-id <N> --lif <uuid>
# Look at: RTT (smoothed, us), RTT mean deviation

# RTT histogram
sudo nicctl show rdma queue-pair path statistics --queue-pair-id <N> --lif <uuid>
# Look at: RTT buckets
```

| What to flag | Means |
|-------------|-------|
| One path RTT >> other paths | Congested switch port on that path's route |
| High RTT mean deviation | Unstable path → RTO miscalculated, premature/late timeouts |
| RTT bucket 3/4 has entries | Tail latency present — occasional spikes |
| RTT much higher than expected (~15-20µs typical) | Network issue, or PCIe/DMA latency |

#### Window hogging — one path dominating

```bash
# Compare cwnd across all paths (take 2-3 samples)
sudo nicctl show rdma queue-pair path --status --queue-pair-id <N> --lif <uuid>
# Compare: Congestion window (effective PWND) across paths

# Compare TX packet count per path
sudo nicctl show rdma queue-pair path statistics --queue-pair-id <N> --lif <uuid>
# Compare: Packets count across paths
```

| What to flag | Means |
|-------------|-------|
| One path cwnd >> others (e.g., 40 vs 2) | Window hogging — one path got most AI increments |
| One path TX packets >> others | Traffic concentrated on one path |
| Dominant path has lower RTT | Lower RTT → faster ACKs → more AI → snowball |
| Non-dominant paths high mul_decr | Other paths getting ECN/loss, pushed down |

**Fix:** Check round_robin_burst (too high = one path gets too much). Check RTT evenness across paths.

#### Path inactivation frequency

```bash
# Check how often paths are deactivated (take 2 samples, compute delta)
sudo nicctl show rdma queue-pair path statistics --queue-pair-id <N> --lif <uuid>
# Look at: Path inactive (congestion) — delta between samples
```

| What to flag | Means |
|-------------|-------|
| `Path inactive (congestion)` growing fast | Paths frequently going cwnd=0 and being removed |
| Multiple paths alternating active/inactive | Bitmap churn — bootstrap overhead eating throughput |

**Key:** ECN-based MD (beta) has **no per-path floor** — it can take cwnd to 0 and inactivate ANY path. This applies even with RCN enabled (rcn_pwnd_min only protects against RCN-triggered MD, not ECN MD).

#### RTO and SACK window reduction

```bash
# Check retransmission counters (take 2 samples, compute delta)
sudo nicctl show rdma queue-pair path statistics --queue-pair-id <N> --lif <uuid>
# Delta of: RTO retransmit packets, SACK retransmit packets
```

| What to flag | Means |
|-------------|-------|
| RTO retx delta > 0 | Loss detected → lambda-based MD reducing window |
| SACK retx delta > 0 | SACK holes → retransmission + potential MD |
| RTO retx growing steadily | Persistent packet loss → window keeps shrinking |
| `RTO retry count at same snd_una` > 2 (path --status) | Consecutive RTOs without progress → path nearing inactivation |

**Key:** Each RTO triggers `qwnd -= loss_count >> log_lambda`. Too many RTOs → window collapses to qwnd_min → cwnd_retry dominates.

#### Retry overhead (cwnd_retry → host memory DMA)

```bash
# Check retry ratio (take 2 samples, compute delta)
sudo nicctl show rdma queue-pair path statistics --queue-pair-id <N> --lif <uuid>
# Compare delta of: CWND retry retransmit packets vs Packets

# Check if S3/S4 is the bottleneck
PAL_CARD_UUID=$CARD_UUID asicmon
# Look at S3/S4: high out xoff? high CH0/CH1? high DMISS?
```

| What to flag | Means |
|-------------|-------|
| CWND retry packets > 20-30% of total packets | Retry overhead significant |
| Retry ring doorbells growing fast | Frequent cwnd exhaustion |
| S3/S4 high out xoff + high CH0/CH1 in asicmon -P | Retry DMA from host memory bottlenecking pipeline |
| Multiple paths with `CWND retry in progress: True` | Simultaneous retry across paths → DMA contention |

**Key:** Retry ring is in HOST MEMORY. Each cwnd_retry reads WQEs over PCIe. With small windows (from aggressive CC or RCN), retry overhead can dominate — pipeline spends more time re-reading old WQEs than sending new data.

### Window reduction sources summary

| Source | Per-path floor | Applies to | Counter to check |
|--------|---------------|-----------|-----------------|
| ECN (beta) | **None — can go to 0** | CC and CC+RCN | `CC multiplicative decrements` |
| Loss/RTO (lambda) | qwnd_min | CC and CC+RCN | `RTO retransmit packets` |
| SACK retransmit | qwnd_min | CC and CC+RCN | `SACK retransmit packets` |
| RCN rate adjustment | rcn_pwnd_min | CC+RCN only | `Rate hints` in QP --status |

### Quick Decision Flow: CC Performance

```
Throughput below line rate + CC enabled?
├── Phase 0: asicmon → pipeline bottleneck? (see 10-performance-debugging.md)
├── Phase 1: QP/path --status → window small?
│   ├── QP CWND at qwnd_min → floor reached
│   ├── paths inactive → bootstrap not triggering
│   └── cwnd_retry on many paths → retry overhead
├── Phase 2: path stats → WHY is window small?
│   ├── mul_decr >> add_incr → ECN or loss hammering
│   ├── RTO retx high → packet loss → lambda MD
│   ├── SACK retx high → SACK-based MD
│   └── Path inactive (congestion) high → frequent inactivation
├── Phase 3: CC profile → parameters appropriate?
├── Phase 4: Network → ECN threshold, FEC, PFC
├── Phase 5: Tune → epsilon, beta, lambda, qwnd_min, minimum_rto
└── Phase 6: Secondary checks
    ├── RTT outliers across paths?
    ├── Window hogging by one path?
    ├── Path inactivation frequency?
    └── Retry overhead (cwnd_retry ratio, S3/S4 asicmon)?
```

---

## CC Performance Debugging — Single Port, With RCN

**Scope:** CC enabled (`congestion_mgmt=1`), RCN enabled (`rcn=1`), single port (`num_ports=1`).

Everything from the CC-only section above applies. This section covers **additional RCN-specific** checks.

For RCN algorithm details, see `01-protocol.md` section 6.4.
For asicmon and pipeline analysis, see `10-performance-debugging.md`.

### Phase 1: Is RCN the limiter?

The primary diagnostic question: **Is QWND at QWND_max?**

```bash
# QP --status shows RCN-specific fields (take 2-3 samples)
sudo nicctl show rdma queue-pair --used --status -c <card-uuid>
# Look at:
#   RCN: Enabled
#   Rate hints (Gbps): <value>
#   QP CWND (whole): <value>
#   QP CWND max: <value>
```

| Condition | Interpretation | Next step |
|-----------|---------------|-----------|
| `QP CWND` ≈ `QP CWND max` | **RCN is capping the window** | Go to Phase 2 (rate hints) |
| `QP CWND` << `QP CWND max` | RCN is NOT the limiter | Follow CC-only workflow (ECN, loss, or other cause) |
| `Rate hints` = 0 | RCN not receiving rate hints | Go to Phase 3 (responder) |
| `RCN: Disabled` | RCN not enabled despite expectation | Check CC profile: `--rcn enable` |

### Phase 2: Why is QWND_max low?

`QWND_max = gamma × rate_hints × (RTT + omega)`

Each factor can make QWND_max too small:

| Factor | Check | Issue |
|--------|-------|-------|
| `rate_hints` too low | QP --status → `Rate hints (Gbps)` | Too many active QPs on responder, or rcn_rate_hints wrong (400 vs 800) |
| `RTT` too low | QP --status → `RTT QP (us)` | Low RTT → small QWND_max. Increase omega for headroom |
| `gamma` too small | CC profile → gamma | Rarely needs changing (1.0 is typical) |
| `omega` too small | CC profile → omega | Increase to add NIC-local delay headroom |

#### rcn_pwnd_min vs QWND_max configuration conflict

Check that `rcn_pwnd_min × num_active_paths` does not exceed `QWND_max`:

```bash
# From QP --status:
#   Active paths: 8, QP CWND max: 20
# From CC profile:
#   rcn_pwnd_min: 4
# Sum of path floors: 8 × 4 = 32 > QWND_max (20) → CONFLICT
```

When `sum(rcn_pwnd_min) > QWND_max`, RCN cannot enforce its target rate — the per-path floors collectively prevent the QP window from reaching the RCN ceiling. The effective QWND stays above QWND_max, and CC accounting may drift (`QP cwnd != sum of path cwnd` anomaly).

**Fix:** Either reduce `rcn_pwnd_min`, or reduce active path count, or increase omega to raise QWND_max above the sum of floors.

### Phase 3: Check responder side

```bash
# On RESPONDER node:
# How many active QPs? (denominator in rate_hints calculation)
sudo nicctl show rdma queue-pair --summary -c <card-uuid>

# What rate_hints value is configured?
sudo nicctl show rdma congestion-control profile -j
# Look at: rcn_rate_hints (400 or 800)

# Is RCN enabled on responder?
sudo nicctl show rdma congestion-control profile -j
# Look at: rcn: enabled/disabled
```

**Rate hint formula:** `rate_hints = (line_rate × active_ports) / (active_QPs × num_ports)`

If active_QPs is large (e.g., 100 QPs on responder), rate_hints per QP will be small → small QWND_max.

### Phase 4: RCN-specific secondary checks (take 2-3 samples)

#### Retry overhead (more severe with RCN)

RCN typically produces smaller windows than CC-only → more cwnd_retry → more host memory DMA.

```bash
# Check retry ratio
sudo nicctl show rdma queue-pair path statistics --queue-pair-id <N> --lif <uuid>
# CWND retry retransmit packets vs Packets — delta between samples

# Check pipeline bottleneck from retry
PAL_CARD_UUID=$CARD_UUID asicmon -P
# S3/S4: high CH0/CH1? high DMISS? → retry DMA saturating pipeline
```

**If retry overhead is the problem:**
- Increase `omega` (adds NIC-local delay headroom → larger QWND_max → larger per-path windows → fewer retries)
- Increase `rcn_pwnd_min` (larger per-path floor → fewer paths go to minimum)
- Reduce path count (fewer paths × larger per-path window = less retry)

#### ECN bypassing rcn_pwnd_min

rcn_pwnd_min only protects against RCN-triggered MD. ECN-based MD (beta) has **no per-path floor** and can take cwnd to 0 even with RCN.

```bash
# Compare per-path: is ECN taking paths to zero?
sudo nicctl show rdma queue-pair path --status --queue-pair-id <N> --lif <uuid>
# Look at: paths with cwnd=0 AND Path disabled (cwnd): True

# Check ECN vs RCN contribution
sudo nicctl show rdma queue-pair path statistics --queue-pair-id <N> --lif <uuid>
# High CC multiplicative decrements + high CNP received → ECN is the culprit
# vs low CNP → RCN is reducing but within rcn_pwnd_min floor
```

#### Rate hints fluctuation

```bash
# Take 3 samples of QP --status a few seconds apart
# Compare Rate hints (Gbps) and QP CWND max across samples
```

| What to flag | Means |
|-------------|-------|
| Rate hints stable across samples | Responder QP count stable — good |
| Rate hints fluctuating | Responder QP count changing (QPs created/destroyed) → QWND_max oscillating |

### Phase 5: Tune RCN parameters

```bash
# Increase omega (NIC-local delay headroom → larger QWND_max)
sudo nicctl update rdma congestion-control profile --profile-id 0 --omega 10

# Increase per-path floor (prevent path starvation under RCN)
sudo nicctl update rdma congestion-control profile --profile-id 0 --rcn-pwnd-min 4

# Set correct rate hints for deployment (400G or 800G)
sudo nicctl update rdma congestion-control profile --profile-id 0 --rcn-rate-hints 400

# Use min RTT for more stable QWND_max calculation
sudo nicctl update rdma congestion-control profile --profile-id 0 --rcn-use-min-rtt enable
```

**Note:** All CC-only tuning (epsilon, beta, lambda, qwnd_min, minimum_rto) also applies to CC+RCN.

### Quick Decision Flow: CC + RCN Performance

```
Throughput below line rate + CC+RCN enabled?
├── Phase 0: asicmon → pipeline bottleneck? (see 10-performance-debugging.md)
├── Phase 1: Is QWND at QWND_max?
│   ├── YES → RCN is the limiter
│   │   ├── Rate hints too low? → too many QPs on responder, or rcn_rate_hints wrong
│   │   ├── RTT too low? → increase omega for headroom
│   │   ├── Retry overhead? → S3/S4 DMA bottleneck from small windows
│   │   │   └── Increase omega or rcn_pwnd_min or reduce path count
│   │   └── ECN bypassing rcn_pwnd_min? → paths going to 0 despite RCN floor
│   ├── NO → RCN not the limiter → follow CC-only workflow
│   └── Rate hints = 0 → RCN not working → check responder CC profile
├── Phase 6 (shared): RTT outliers? Window hogging? Path inactivation? Retry overhead?
└── Tune: omega, rcn_pwnd_min, rcn_rate_hints, rcn_use_min_rtt
```

## CC Performance Debugging — Multi-Port

**Scope:** `num_ports > 1`. Applies to both CC-only and CC+RCN. All single-port CC/RCN
checks above still apply — this section covers **additional multi-port issues**.

For multiplane architecture, see `01-protocol.md`. For path selection with port groups, see `02-tx-pipeline.md` section 5.

### Per-Port Congestion Asymmetry

Different ports traverse different switch paths → different congestion levels.

```bash
# Compare per-path stats GROUPED BY PORT (take 2-3 samples, compute deltas)
sudo nicctl show rdma queue-pair path statistics --queue-pair-id <N> --lif <uuid>
# Group paths by port (path 0..max_paths_per_port-1 = port 0, etc.)
# Compare: CC mul_decr, CNP received, RTO retx per port group

# Compare per-path cwnd grouped by port
sudo nicctl show rdma queue-pair path --status --queue-pair-id <N> --lif <uuid>
```

| What to flag | Means |
|-------------|-------|
| One port's paths have much higher mul_decr | That port's switch path has more congestion/ECN |
| One port's paths all have cwnd=1-2, others healthy | Port-level congestion collapsing that port |
| One port's paths have higher RTT | Congested or longer switch path on that port |

### Window Hogging by Port

One port may accumulate most of the QP window because its paths have lower RTT
(→ faster ACKs → more AI increments) or less ECN (→ fewer MD events).

```bash
# Sum cwnd across paths per port (take 2-3 samples)
# Port 0 total cwnd vs Port 1 total cwnd
# If one port >> other → window hogging by port
```

| What to flag | Means |
|-------------|-------|
| Port 0 total cwnd = 40, Port 1 total cwnd = 6 | Port 0 hogging window |
| Dominant port has lower avg RTT | Lower RTT → faster ACKs → more AI → snowball |
| Non-dominant port has higher CNP received | More ECN on that port → more MD |

### ECN/PFC Per-Port Differences from Switch

Switch may have different ECN thresholds or PFC configuration per port.

```bash
# Compare CNP received per path, group by port (take 2-3 samples, delta)
# If one port's paths have >> CNP than others → switch ECN threshold different on that port
```

**Fix:** Check switch ECN/WRED threshold configuration per port. Ensure consistent thresholds.

### RCN rate_hints with Port Changes

`rate_hints = (line_rate × active_ports) / (active_QPs × num_ports)`

When a port goes down:
- `active_ports` decreases → rate_hints per QP changes for ALL QPs on that NIC
- QWND_max shifts suddenly → can cause window adjustments across all QPs
- Remaining ports absorb traffic → may trigger ECN/congestion on those ports

```bash
# QP --status: check Rate hints (Gbps) before and after port failure
# Compare across 2-3 samples to see if rate_hints is stable
```

### Port Failover Cascade

When one port fails, traffic shifts to remaining ports → more traffic per port → more congestion:

```
Port A fails → traffic shifts to Port B, C
  → Ports B, C now carry 1.5x traffic
    → More ECN/congestion on B, C
      → cwnd shrinks on B, C paths
        → If severe: B, C paths also go to cwnd=0 → cascade failure
```

**Detection (take 3+ samples over time):**
```bash
# Track path inactivation rate across ports
# If Port A paths inactive, then Port B paths start going inactive → cascade
sudo nicctl show rdma queue-pair path statistics --queue-pair-id <N> --lif <uuid>
# Delta of: Path inactive (congestion) per path, grouped by port
```

### Per-Port RTT Differences Affecting RCN

Different ports → different network paths → different RTTs.
With RCN: QWND_max = gamma × rate × (RTT + omega) uses QP-level RTT, but per-path
AI rate depends on per-path RTT (faster ACKs = more AI increments).

```bash
# Compare RTT across paths, group by port (take 2-3 samples)
sudo nicctl show rdma queue-pair path --status --queue-pair-id <N> --lif <uuid>
# Port 0 paths avg RTT vs Port 1 paths avg RTT
```

Paths on lower-RTT ports get more AI → accumulate more cwnd → port imbalance.

### Retry Overhead Amplified by Multi-Port

More ports × more paths × smaller per-path windows = more cwnd_retry events.
All retry reads from host memory → more PCIe DMA contention.

```bash
# Check total CWND retry across all paths (take 2 samples, delta)
sudo nicctl show rdma queue-pair path statistics --queue-pair-id <N> --lif <uuid>
# Sum CWND retry retransmit packets across all paths

# Check pipeline bottleneck
PAL_CARD_UUID=$CARD_UUID asicmon -P
# S3/S4: high CH0/CH1? high DMISS? → retry DMA saturating pipeline
```

With RCN making windows smaller + more paths across ports → retry amplification is worst
in multiplane + RCN configurations.

### Window Accounting After Port Events

When force_inactivate removes paths on a failing port, their cwnd is decremented from QP CWND.
If many paths on one port are force-inactivated simultaneously → large QP CWND drop.

```bash
# Check for QP cwnd accounting anomaly
sudo nicctl show pipeline internal rdma anomalies
# Look for: "QP cwnd N != total paths cwnd M"
```

### Quick Decision Flow: Multi-Port Performance

```
Throughput below line rate + num_ports > 1?
├── All ports UP? (nicctl show port)
│   └── NO → port down → force_inactivate cascade (see correctness section)
├── Per-port congestion asymmetry?
│   ├── Compare cwnd per port → one port's paths much lower?
│   ├── Compare mul_decr per port → one port getting more ECN?
│   └── Compare RTT per port → one port higher RTT?
├── Window hogging by port?
│   └── Sum cwnd per port → one port >> others?
├── Port failover cascade?
│   └── Path inactive (congestion) growing on multiple ports sequentially?
├── RCN rate_hints shifting after port change?
│   └── Compare Rate hints across samples
├── Retry overhead amplified?
│   └── High CWND retry total + S3/S4 DMA bottleneck?
└── All single-port CC/RCN checks still apply (see above sections)
```

---

# Part 4: Cross-Node Correlation

Applies to both correctness and performance debugging.

### One-Sided vs Two-Sided Classification

| Anomalies on sender | Anomalies on receiver | Likely cause |
|-----|-----|------|
| YES | Clean | Sender-side issue |
| Clean | YES | Receiver dropping or not ACKing |
| YES | YES | Network loss |
| Clean | Clean | Above NIC layer (app, driver, OS) |

### Correlation Rules

| Anomaly on Side A | Check on Side B |
|---|---|
| SQ: "ack_msn not advancing" | Peer RQ: drops? Path RX: ack ring stuck? |
| Path TX: "retx active but ACKs not arriving" | Peer Path RX: ack ring stuck? |
| Path TX: "cwnd_retry stuck" | Peer Path RX: sending ACKs? |
| Path RX: "ack ring stuck" | Peer Path TX: will see retx storm |
| Path RX: "receiver gap growing" | Check switch FEC/drops |

### Sequence Number Cross-Check

- Sender `snd_nxt` ≈ Receiver `max_fsn + 1`
- Sender `snd_una` ≈ Receiver's last ACK cfsn
- snd_una far behind rcv_nxt → ACKs lost on return path
- max_fsn far behind snd_nxt → data lost on forward path

### Statistics Delta Matching

- Sender `TX packets` ≈ Receiver `RX packets` (difference = loss)
- Sender `RTO retx` growing, receiver `drops` = 0 → ACK return path problem
- Sender `CC mul_decr` high, receiver `ECN received` = 0 → ECN not reaching sender

### RTT Outlier Detection

- Compare RTT across paths — one outlier = congested switch port
- All paths high → systemic issue

### How to Identify the Peer

From QP `--status`: `SrcIP=X, DstIP=Y, RemoteQP=N`
Peer: `SrcIP=Y, DstIP=X, LocalQP=N`
