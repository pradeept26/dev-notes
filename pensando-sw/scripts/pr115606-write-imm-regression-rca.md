---
title: "RCA: PR #115606 Write-with-Immediate Regression"
date: 2026-05-12
pr: https://github.com/pensando/sw/pull/115606
firmware: 1.125.0-pi-232 (PR #115606 + pcie_qos.diff)
baseline: 1.125.0-a-232
cluster: smc1 (10.30.75.198) + smc2 (10.30.75.204), Vulcano, Hydra
reproducer: "ib_write_bw -d roce_benic1p1 -q 2 -n 10000 --write_with_imm -b --report_gbits -p 18515 -s 1024"
status: Root cause identified — timer loss detection broken on requester side
---

# RCA: PR #115606 Write-with-Immediate Regression

## Summary

PR #115606 ("meta_roce: tighten path inactivation and gate AI on window-limited
paths") introduces a regression where `ib_write_bw --write_with_imm` hangs at
small message sizes (1K). The test completes in ~1s on baseline firmware but
hangs indefinitely on the PR build. Large messages (8M) are unaffected.

## Regression Confirmed

| Test | Baseline (1.125.0-a-232) | PR Build (1.125.0-pi-232) |
|------|-------------------------|--------------------------|
| `--write_with_imm -q 2 -s 1024 -b` | **PASS** (43.46 Gb/s, 1.07s) | **HANG** (no data, timer broken) |
| `--write_with_imm -q 2 -s 8M -b` | not tested | **PASS** (42.57 Gb/s) |
| `ib_write_bw -q 2 -s 8M -b` (no imm) | not tested | **PASS** (716.59 Gb/s) |

## Failure Signature

On the PR build, after ~0.5s of traffic the system reaches a terminal state:

### Requester side (smc-2, sender of data):
- **All paths**: `timer_started=1` but `pi_timer == ci_timer` (no timer event pending)
- Anomaly: **"timer_started but no timer event pending — loss detection broken"**
- `snd_una` frozen, `snd_nxt > snd_una` (6-10 packets outstanding per path)
- `cwnd_retry = 0`, `path_removed_tx = 0`, `path_removed_rx = 0` (paths in bitmap)
- `rto_retx_snd_una` matches `snd_una` (RTO retransmit tracking stale)
- SQ: `ack_msn` not advancing, 74-86 unacked messages

### Responder side (smc-1, receiver of data):
- **Several paths**: `rcv_nxt < max_fsn` with FSN bitmap gaps (e.g., `0x1c0`, `0x40`)
- Anomaly: **"receiver has data to ACK but ack ring is empty — ACK generation broken"**
- `send_ack_pi == pi_ack == ci_ack` (ack ring fully drained, no new ACKs queued)
- Packets received OOO but the missing FSNs can never arrive (requester timer broken)

### Deadlock Chain:
```
smc-2 requester: timer_started=1 but no timer event
  → retransmit timer never fires
  → lost packets never retransmitted
  → smc-1 receiver has FSN gaps, can't advance rcv_nxt
  → smc-1 can't ACK (already sent ACK for rcv_nxt, no new data to trigger ACK)
  → smc-2 never receives ACKs
  → snd_una never advances
  → permanent stall
```

## Detailed Path State Evidence

### smc-2 (requester) QP 2, Path 2 (representative stuck path):
```
pathcb2.snd_nxt       = 0x7c (124)
pathcb2.snd_una       = 0x74 (116)   ← 8 packets outstanding
pathcb2.cwnd          = 0x7 (7)      ← outstanding > cwnd!
pathcb2.timer_started = 0x1          ← timer armed
pathcb2.cwnd_retry    = 0x0          ← NOT in cwnd_retry
pathcb2.path_removed_tx = 0x0        ← path in bitmap
pathcb2.path_removed_rx = 0x0
pathcb0.pi_timer      = 0x2c9e       ← pi == ci (no pending event!)
pathcb0.ci_timer      = 0x2c9e
pathcb0.pi_retx_rto   = 0x2c98       ← pi == ci (retx done)
pathcb0.ci_retx_rto   = 0x2c98
```

### smc-1 (receiver) QP 2, Path 6 (representative broken-ACK path):
```
pathcb1.rcv_nxt       = 0x76 (118)
pathcb1.max_fsn       = 0x7e (126)   ← 9 FSN gap
pathcb1.fsn_bitmap_3  = 0x1c0        ← bits for FSN 124,125,126 set (received OOO)
pathcb1.send_ack_pi   = 0x79         ← matches pi_ack
pathcb0.pi_ack        = 0x79         ← == ci_ack (ack ring empty)
pathcb0.ci_ack        = 0x79
```

## Root Cause Analysis

The failure is a **timer event loss** on the requester side. The timer is marked
as started (`timer_started=1`) but the timer ring has no pending event
(`pi_timer == ci_timer`). Without the timer firing, RTO-based loss recovery
never happens.

### Why this happens with PR #115606:

The PR changes the path removal threshold in tx_s3 from `outstanding >= cwnd`
to `outstanding + 1 >= cwnd` (line 112 of tx_s3.p4 in the diff):

```p4
// OLD:
if (__unlikely((int<16>)outstanding_pkts >= cwnd)) {
// NEW:
if (__unlikely((int<16>)outstanding_pkts + 1 >= cwnd)) {
```

And `cwnd_overflow` is now only set on TRUE overshoot:
```p4
// NEW: only fires on actual overshoot, not on the +1 early removal
if (((int<16>)outstanding_pkts >= cwnd)) {
    p.cwnd_overflow = 1;
}
```

The `__memory_write_h` for `snd_nxt_mirror` was also added to tx_s3's normal
send path, cwnd_retry path, and SACK retx path.

### The race condition:

With small messages (cwnd=6-7 packets at 1K), the `outstanding + 1 >= cwnd`
threshold triggers path removal very frequently. In bidirectional write-with-imm
traffic, both sides are sending AND receiving simultaneously. The tight
interaction between:

1. **tx_s3**: removes path, flips `path_removed_tx`, starts timer
2. **rx_s3**: processes incoming ACKs, tries to re-add path
3. **Timer hardware**: receives `__start_timer()` request

creates a window where the timer start and the path bitmap update race through
separate SDP channels. On Vulcano, tx and rx PHVs use separate SDP channels
(as documented in the rx_s3 comment about the phv1/phv2/phv3 race). A tx PHV
that starts the timer can race with an rx PHV that processes an ACK and updates
path state. If the rx PHV overtakes the tx PHV at the timer/scheduler hardware
level, the timer event can be consumed or cancelled before it's properly armed.

### Why small messages are affected:

- Small messages (1K) with cwnd=6-7 means only 6-7 packets before window closes
- At high packet rates, the `outstanding + 1 >= cwnd` triggers on nearly every
  packet, creating very high path removal/re-addition churn
- Each removal attempt starts a timer and potentially triggers cwnd_retry
- The timer start races with ACK processing on the rx side
- Large messages (8M = ~2 packets at MTU 4096) rarely hit the window limit

### Why baseline doesn't have this issue:

The baseline uses `outstanding >= cwnd` (strict, not +1), and keeps the
`cwnd_retry_path_removed` bit which prevents redundant path removal/re-addition.
The baseline also re-adds the path from tx_s3's cwnd_retry completion, reducing
the dependency on rx_s3 for re-activation. This results in fewer path bitmap
transitions and fewer timer start/cancel races.

## Evidence Against Alternative Hypotheses

1. **Not a path bitmap deadlock**: All paths show `path_removed_tx == path_removed_rx`
   and `cwnd_retry == 0`. Paths ARE in the bitmap but can't make progress.

2. **Not a va_no_page issue**: The va_no_page seen earlier was a secondary failure
   after prolonged stall. Fresh reset+bringup reproduces the timer issue cleanly.

3. **Not RCQ-related**: smc-1's RQ for QP 2 shows `rqcb1.bmsn = 0x34b` (843 received)
   vs smc-2's SQ `sqcb0.msn = 0x3a1` (929 sent). The gap is exactly the outstanding
   unacked packets, not an RCQ backlog.

4. **Not a write-imm specific code path issue**: The PR doesn't modify any
   write-imm-specific code. The issue is that write-imm bidirectional creates
   higher pipeline pressure (both RX data and TX data active simultaneously)
   which increases the probability of the timer race.

## Reproducer

On smc-1 (server): `ib_write_bw -d roce_benic1p1 -q 2 -n 10000 --write_with_imm -b --report_gbits -p 18515 -s 1024`
On smc-2 (client): `ib_write_bw -d roce_benic1p1 -q 2 -n 10000 --write_with_imm -b --report_gbits -p 18515 -s 1024 10.30.75.198`

Reproduces 100% on PR build, passes 100% on baseline.

## Suggested Fix

The `outstanding + 1 >= cwnd` threshold change creates too much path removal
churn with small windows. Options:

1. **Revert to `outstanding >= cwnd`** for the removal threshold (safest)
2. **Add hysteresis**: only remove path if `outstanding + 1 >= cwnd` AND the
   path hasn't been removed in the last N cycles
3. **Fix the timer race**: ensure `__start_timer()` and path bitmap updates
   are atomic or properly ordered across SDP channels
4. **Restore tx_s3 path re-add in cwnd_retry completion**: reduce rx_s3
   dependency for path re-activation

## Diagnostic Files

- `/tmp/diag_smc1_anomalies.txt` — smc-1 pipeline anomalies during hang
- `/tmp/diag_smc2_anomalies.txt` — smc-2 pipeline anomalies during hang
- `/tmp/diag_smc1_paths.txt` — full path CB state smc-1
- `/tmp/diag_smc2_paths.txt` — full path CB state smc-2
- `/tmp/diag_smc1_qp.txt` — QP state smc-1
- `/tmp/diag_smc2_qp.txt` — QP state smc-2
