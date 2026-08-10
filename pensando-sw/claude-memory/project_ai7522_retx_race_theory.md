---
name: AI-7522 retx-ring off-by-one race theory (exact_cwnd_enforce)
description: Detailed root-cause theory for AI-7522 — retx_pi vs snd_max accounting race in tx_s3 exact_cwnd_enforce path
type: project
originSessionId: ed1d2263-4f88-4057-a807-36c650c1b845
---
Root-cause theory for AI-7522 (Hydra multi-QP bidir BW stall). Status: strongly supported by live
ring dump + source; exact concurrent interleave not yet serialized (trace/gtest pending). a-85 vs a-86
regression test in progress.

## The invariant that must hold
Retransmit reads the oldest unacked WQE via `retx_idx = retx_ci + (snd_cur - snd_una)` (tx_s1:666,
tx_s3:216), and takes the wire FSN from that loaded WQE (tx_s3:477). Correctness requires
**`WQE[retx_ci] == snd_una`**.

## Two counters that must agree but don't
- `retx_pi` (ring producer): bumped on EVERY req_tx packet — `_retx_wqe_dma_cmd_add` at tx_s3:588,
  unconditional (runs in both allow and else branches).
- `snd_max` (retry/record accounting): bumped only in the window-blocked else branch (tx_s3:541) or by
  the snapshot `snd_max = snd_nxt` (tx_s3:87) taken when the path flips into cwnd_retry (cwnd_retry 0->1).
- `snd_nxt` (sent cursor): bumped in req_tx allow (tx_s3:533) and by the cwnd-retry drain
  `_path_cwnd_retry_process` (tx_s3:225).
- Free side (ACK): `snd_una` and `retx_ci` advance together by pkts_freed (rx_s3:232, 252). Consistent.

Each isolated path preserves the invariant. The break is at the allow->cwnd_retry boundary in
`_window_check` (tx_s3:74-146, exact_cwnd branch 80-112): `snd_max = snd_nxt` (:87) is a NON-ATOMIC
snapshot of snd_nxt, while `retx_pi++` (:588) fires on every packet. last_pkt (tx_s3:84-85) transmits+
records (snd_nxt++, retx_pi++) WITHOUT bumping snd_max; unconditional path removal at 108-110.

## The race (likely)
Under 2-QP bidirectional load two contexts touch the same path CB concurrently: req_tx (SQ pipeline,
does retx_pi++ and the :87 snapshot) and either a second in-flight req_tx (other QP) or the cwnd-retry
drain (path pipeline, snd_nxt++ at :225). A packet is recorded (retx_pi++) in the small window between
the :87 snapshot READING snd_nxt and that packet's snd_nxt++ COMMITTING, so the snapshot misses it.
Net: `retx_pi = snd_max + 1` — one phantom ring slot. Devs already flag this region racy (tx_s3:104-107
"to avoid any race conditions ... unconditionally remove the path here").

## Worked example (cwnd=4, snd_una=100)
Serial (correct): send 100,101,102 (allow), 103 (last_pkt, allow, snd_max stays 100), 104 trips retry ->
snapshot snd_max=snd_nxt=104 captures all -> retx_pi-retx_ci = snd_max-snd_una = 5, WQE[retx_ci]=100. OK.
Racy: at boundary, packet B photographs snd_nxt=103 for `snd_max=103` BEFORE packet A's snd_nxt++ (to
104) commits, but A's retx_pi++ (box slot) lands -> manifest short by one -> retx_pi = snd_max+1 ->
WQE[retx_ci] shifts to snd_una-1.

## Downstream effect (matches live capture)
retransmit reads slot retx_ci = FSN snd_una-1 (already ACKed) -> re-sends a dup forever
(num_rx_dup ~2.4M); the true hole FSN snd_una is never re-sent -> receiver rcv_nxt frozen -> no
cumulative ACK -> sender snd_una frozen -> symmetric livelock. Live dump proof (path 5): retx_pi=274,
retx_ci=245, snd_una=757, snd_nxt=snd_max=785 -> occupancy 29 vs outstanding 28; WQE[245].fsn=756=snd_una-1.

## Confirmation
Disabling exact_cwnd_enforce (removes snd_nxt/snd_max split + :87 snapshot) -> 2QP AND 8QP full sweep
pass clean, 0 anomalies. With it enabled -> hard hang. `nicctl update pipeline rdma congestion-control
profile -p 0 --exact-cwnd-enforce disable` (both nodes, fresh QPs).

## Fix direction
Advance snd_max in lock-step with retx_pi/snd_nxt in the allow branch (or derive ring occupancy from a
single counter), and close the _window_check boundary so two concurrent packets can't both take last_pkt.

## Open / next
- Serialize the exact interleave (MPU trace of req_tx/_path_cwnd_retry_process at stall onset, or a
  gtest driving the allow->cwnd_retry boundary on 2 QPs asserting retx_pi-retx_ci == snd_max-snd_una).
- Regression: test a-85 (believed good) with exact_cwnd_enforce ENABLED on a separate NIC pair; if no
  repro -> bug introduced a-85->a-86, bisect tx_s3 change.
- Pradeep has follow-up questions on this theory.
