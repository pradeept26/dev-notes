---
name: AI-7522 reproduces on IPv4 — multi-QP bidir BW datapath stall
description: AI-7522 (Hydra IPv6 PF datapath stall) reproduces on SMC over IPv4 at QP>=2 bidir BW; likely NOT IPv6-specific
type: project
originSessionId: ed1d2263-4f88-4057-a807-36c650c1b845
---
AI-7522 filed as "1.130.0-a-86 Hydra IPv6 PF datapath — 5/8 IB verbs fail (spec_failure rollback,
ACK generation broken, 120s timeout, sq/rq anomalies)". Reproduced on SMC (smc1/smc2, dual-node
Vulcano, benic1p1 pair, roce_benic1p1, host memory) on build 1.130.0-a-86 — 2026-08-10.

**Findings:**
- IPv4 (control, `-x 1`): latency 1QP (send/write, incl `_imm`) all PASS. BW 8QP bidir all FAIL —
  `ib_send_bw` stalls @16B (exact CI match), `ib_write_bw` "Failed to sync", both `_imm` hit
  perftest "Did not get Message for 120 Seconds". Same spec_failure/"ACK generation broken" sq/rq/path
  error state as the ticket.
- QP discriminator (`ib_write_bw` bidir, IPv4): QP=1 PASS (clean, no anomalies); QP=2 FAIL; QP=8 FAIL.
- => Trigger is **multi-QP (>=2) bidirectional BW**, NOT IPv6 and NOT SMC QoS (QP=1 clean rules both out).
  Ticket read as IPv6-only only because CI ran the ipv6 spec; no IPv4 comparison was in the ticket.

**ROOT CAUSE CONFIRMED (2026-08-10):** the stall is caused by **`exact_cwnd_enforce`** (cwnd-retry path).
- retx-ring off-by-one proven from a live ring dump (edma_copy+memrd of pathcb2.retx_ring_addr):
  `WQE[retx_ci].fsn == snd_una-1`, occupancy = outstanding+1 (the `retx ring mismatch` anomaly).
- Source: TX `retx_pi` vs `snd_nxt` increment asymmetry in `tx/meta_roce_tx_s3.p4` — `_retx_wqe_dma_cmd_add`
  (retx_pi++) unconditional at :588 vs `snd_nxt++` window-gated at :533; cwnd-retry `_path_cwnd_retry_process`
  advances snd_nxt w/o retx_pi at :225. Invariant `retx_pi-retx_ci == snd_nxt-snd_una` drifts by 1 across the
  window-blocked(else,:539-555)→cwnd-retry drain → orphaned ring entry → retransmit reads wrong WQE → the
  cumulative-edge FSN is never correctly resent → rcv_nxt frozen → symmetric livelock.
- **WORKAROUND (empirically verified):** `sudo nicctl update pipeline rdma congestion-control profile -p 0
  --exact-cwnd-enforce disable` on BOTH nodes, then fresh QPs. 2QP -s1M and 8QP full `-a` sweep BOTH pass
  clean (0 anomalies) vs hard hang with it enabled. exact_cwnd_enforce is set from CC profile
  (`nicmgr.c:1355 g_rdma_congestion_control[].exact_cwnd_enforce_enable`); bringup re-enables it (default on).
- Pending: real fix in tx_s3 retx_pi/snd_nxt accounting so exact_cwnd_enforce can stay enabled.

**Why it matters:** reframes AI-7522 from an IPv6 bug to an IP-version-independent multi-QP bidir BW
datapath stall, root-caused to exact_cwnd_enforce. Reporter: Gautham K G.

**How to apply:** When discussing/triaging AI-7522, lead with the IPv4 + QP>=2 repro. IPv6 direct
comparison on SMC is blocked (Micas switch 10.30.75.77 IPv6 ND broken: SVIs up/up but ND FAILED
bidirectionally; IPv4 routes fine). Not yet done: QP threshold is >=2; not yet bisected to a regressor.
