# RCCL alltoallv hang (RCN disabled) — wedged QP capture

Captured 2026-07-20 from the live 16h-wedged run (FW 1.130.2-a-4, GT Vulcano multiplane,
GT-1 10.30.69.101 / GT-4 10.30.69.98, 8 NICs, 4x100G, path count 8, back-to-back).

## Wedged QP
- Requester (wedged): GT-4 (10.30.69.98), bdf 0000:03:00.0, lif 02000070-0100-0000-4242-0490818f1e40, qp 23
- Peer (responder waiting): GT-1 (10.30.69.101), lif 02000070-0100-0000-4242-04908199dd40, qp 23

## Key state (GT-4 qp23, requester)
- Queue state: RTS (rollback, spec_cindex=202, restart_ci=202)
- Active/Disabled/Inactive/Max paths: 0/5/3/8   (0 usable paths)
- qp_cwnd_whole=0, qp_cwnd_fraction=0x38, qp_cwnd_whole_tx==rx=0x1db0
- MSN=56523, BMSN=56524, CSN=56522  (1 message outstanding, never completes)
- path_bitmap=0, inactive_path_bitmap=0x19 (local paths 0,3,4); paths 1,2,5,6,7 = disabled/stuck cwnd=0
- Firmware anomaly: "[SQ 0023] ack_msn not advancing (ack_msn=56522, bmsn=56524)"
- Fully frozen: 0 progress over 30s on qp_cwnd_whole_tx / num_cnt_path_bootstrap / num_cnt_path_disabled

## Peer (GT-1 qp23) confirms cross-node
- GT-1 send side healthy (4/0/4, cwnd=15); GT-1 responder for the reverse flow: Expected CSN=56522,
  waiting on message 56522/56523 that GT-4 cannot send.

## Root cause (summary)
RCN off => per-path ECN/SACK MD floor = 0 (rx_s3.p4:173-175) => per-path cwnd collapses to 0 under
alltoallv internal-CNP storm (0 loss, 0 ECN, PFC off by design). qwnd (sum of per-path windows)
collapses to 0. Bootstrap can't recover: trigger (a) num_active==0 is defeated (5 disabled paths
counted as active), trigger (b) (num_active+1)<<aws < qwnd is defeated (qwnd=0 << 96). No active path,
no bootstrap, no send => deadlock. RCN masks it (rcn_pwnd_min keeps cwnd>0).
Secondary: disabled paths drained at cwnd=0 never demote to inactive (rx_s3.p4:258-273 has no cwnd<=0
else, unlike sibling at :300-304).

## Files (per side)
- 02_anomalies, 10_qp_status, 11_qp_raw, 13_qp_json
- 20_path_status, 21_path_raw, 22_path_stats, 23_path_stats_json (+ 24_path_stats_drop on GT-4)
- GT-4 also: 00_version, 01_card, 03_cc_profile_p0, 04_qp_summary
