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
- Regression CONFIRMED (2026-08-10): a-85 with exact_cwnd_enforce ENABLED does NOT repro — 2QP -s1M and
  8QP full -a sweep both pass clean (0 anomalies) on benic2 (BDF 23:00.0) both nodes. a-86 same config =
  hard hang. => bug introduced a-85 -> a-86. Next: diff/bisect tx_s3 (retx_pi/snd_max/snd_nxt/cwnd_retry
  accounting) between the a-85 and a-86 SHAs.
- Test matrix: a-86+exact=hang, a-86+no-exact=clean, a-85+exact=clean.

## Regressor (a-85 65a29968a76 .. a-86 d3f76cbfb14)
- NO hydra P4 change in range -> race was always latent in P4; a shared-firmware change exposed it.
- Prime suspect: **fe8a85350ea "rdma: dynamic RQ TX UD separation (#118857)"** — only commit touching the
  Vulcano TXS scheduler (asicpd/vulcano/vulcano_txs_scheduler.c, scheduler_vulcano.c/.cc) + shared
  nicmgr/eth_lif.c.
- Mechanism: hydra is 2-UD (NICMGR_NUM_UDMA=2; UXDMA_PORT_LB_SELECT(id)=TM_PORT_DMA1+(id&1); per-UD
  rdma_path_qid_allocator). Per-qgrp UD toggle in tx_map_to_qgrp is gated by CONFIG_UXDMA_MODE_2UD; qgrp
  allocation uses qgrp_lb=100/lb_stride. The per-CB (path_cb2) table lock only serializes WITHIN one UD;
  cross-UD there is NO shared lock -> concurrent req_tx(qtype3)+path_tx(qtype0) RMW of snd_nxt/snd_max/
  retx_pi = lost update = the off-by-one.
- fe8a's likely hydra-affecting (non-Quasar-gated) side effect: eth_lif.c copies pipeline_impl lb_stride
  back into lif_info.queue_info for ALL qtypes -> feeds updated lb_stride into TXS qgrp mapping -> shifts
  qgrp numbering/UD parity -> can move SQ(req_tx) and PATH(path_tx) from same-UD (a-85) to different-UD
  (a-86). RQ lb_stride=100 itself is Quasar-only (#ifdef QUASAR), so hydra impact is via the general
  copy-back, NOT proven 100% statically.
- CAVEATS: (1) a-85(benic2) vs a-86(benic1) test used DIFFERENT physical cards -> possible timing confound;
  controlled same-card A/B needed. (2) capview per-qgrp UD dump (rx_sxdma in TXS qgrp_cfg_0) on both cards
  would empirically confirm SQ/PATH same-UD in a-85 vs split in a-86. capview on host:
  sudo bash -lc "TERM=dumb /usr/sbin/capview --bdf <BDF> -f /etc/amd/ainic/vulcano/rudra/hydra/capviewdb.bin < cmdfile"

## CAPVIEW CONFIRMATION (2026-08-10) — cross-UD theory CONFIRMED
Register: txs{0,1}_dhs_sch_qgrp_cfg_0_sram_entry (txs0 base 0x22318000, txs1 0x22518000, 2048 rows).
Fields: lif_idx[20:10], rx_sxdma[3:2]=UD, cos[7:4], qid_start/end, disabled[9], auto_clear[0].
LIFs: PF/SQ+RQ = lif_idx 0x11 (txs0). PATH service lif (RUDRA_HYDRA_PATH_LIF=70) = hw sched lif_idx 0x6 (txs1),
cos 2/3, qid 0x0..0x3fff. Both cards on smc1: benic1=a-86 BDF 0000:06:00.0, benic2=a-85 BDF 0000:23:00.0.
Dump/parse script: /tmp/cvdump.sh <bdf> <lif_hex> (NB: don't name awk var 'cos' — it's the builtin cosine).
RESULT:
- PATH lif 0x6 (txs1): IDENTICAL a-86 vs a-85 — 4 qgrps spread ud=1/2 (UD0/UD1). path_tx unchanged.
- PF/SQ lif 0x11 (txs0): a-85 = 8 fine qgrps spread ud 0/1/2 (per-UD, paired with PATH); a-86 = 2 coarse
  qgrps both ud=0 (COLLAPSED). => a-85 SQ<->PATH co-located same-UD (serialized, safe); a-86 SQ collapsed
  to ud=0 while PATH stays ud=1/2 => SQ(req_tx) and PATH(path_tx) on DIFFERENT UDs => per-CB lock no longer
  serializes => cross-UD lost update on snd_nxt/snd_max/retx_pi => hang. CONFIRMS cross-UD race.
OPEN: exact rx_sxdma encoding (0=default-parity vs UD0) + map a specific QP's SQ qid & PATH qid to prove
per-QP UD mismatch; but directionally consistent and confirms fe8a collapsed the SQ UD spread.
- Testbed state after test: benic2 on a-85 (exact enabled); benic1+others on a-86 (exact re-enabled
  globally by the test). exact_cwnd_enforce is profile-0 global (not per-card) via nicctl update.
- Pradeep has follow-up questions on this theory.
