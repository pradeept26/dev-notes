---
name: IPv6 RCCL single-node failure = ud_loopback + IPv6 template bug
description: Single-node (P2P-off) RCCL over IPv6 GID fails at responder VA2PA KT_RANGE_CK; root-caused to the ud_loopback datapath mishandling the 62B IPv6 header template. TX-side suspected.
type: project
originSessionId: 531896b5-3827-4e61-b624-b34520ee5c42
---
Investigation on SMC-1 (2026-07-28). Single-node RCCL with P2P disabled, run over **IPv6** (`NCCL_IB_ADDR_FAMILY=AF_INET6`, `NCCL_IB_GID_INDEX=2`, GID = global `2001:db8:N::1`) fails immediately; IPv4 (GID idx1 `::ffff:30.1.N.1`) works.

**Failure chain (confirmed via live qstate + on-NIC mputrace + source):**
- NCCL: WC `status=11 (IBV_WC_REM_OP_ERR)` / `vendor err 10`.
- Requester qstate `sqcb4.qp_err_dis_remote_oper_err=1` (received NAK OP_ERR); `pathid_uns=0`.
- Responder qstate `rqcb2.qp_err_dis_key_va_err=1`.
- mputrace on benic1 responder: RDMA WRITE (`opcode 0xc6`), VA2PA `probe_common_sts_err=0x87` = `VA2PA_ERR_KT_RANGE_CK` (135), `ack_info_status=0x63` (AETH NAK `0x60|OP_ERR`). Failing action = `resp_rx_key_va_send_fail` (`meta_roce_rx_comp_utils.p4`).

**Root cause = ud_loopback path + IPv6 template (NOT an IPv6 parser bug):**
- Failing single-node QPs have **`ud_loopback=1`** on both SQ and RQ (`sqcb0/sqcb2.ud_loopback`, `rqcb0.ud_loopback`), dst_qp cross-pointing (intra-NIC loopback), and `header_template_size=0x3e` (62B = Eth14+IPv6 40+UDP8; IPv4 would be 0x2a/42B).
- 3-way mputrace matrix (benic1 responder VA2PA, all opcode 0xc6):
  - IPv6 + single-node loopback (ud_loopback=1, 62B): **FAIL** `sts_err=0x87`.
  - IPv6 + inter-node (ud_loopback=0, 62B): PASS `sts_err=0x0`, 45.5 GB/s.
  - IPv4 + single-node loopback (ud_loopback=1, 42B): PASS `sts_err=0x0`.
- So inter-node IPv6 (parse) works and IPv4 loopback (path) works; only IPv6×loopback breaks → the ud_loopback datapath mishandles the larger 62B IPv6 header template.

**Trigger is IP-gated in the CONTROL PLANE, not the parser:** `nicmgr_is_loopback_mac(ah.dmac, lif)` (`nic/sdk/rtos-shared/src/lib/nicmgr/core/nicmgr.c:592`) returns true iff AH dmac == the QP's own lif MAC. In `admincmd_handler.c` (~1577, sets at 3106-3108) this makes `ud_loopback=1` for IPv6 self-writes (AH dmac resolves to own MAC) but `ud_loopback=0` for IPv4 (dmac resolves to non-own/next-hop). Verified across ALL used QPs (2/3 and 2048/2049) both runs: IPv4 loopback all ud_loopback=0 (42B tmpl), IPv6 loopback all ud_loopback=1 (62B tmpl).

**IMPORTANT refinement (2026-07-28): ud_loopback=1 is necessary but NOT sufficient.** Simple `ib_write_bw` IPv6 same-NIC loopback on SMC2 (stock a-55) **PASSES** even though its client QP has `ud_loopback=1` (62B tmpl). So the ud_loopback WRITE path is not universally broken — RCCL adds an extra factor. Candidates: (a) multipath (RCCL max_paths=8/path_id vs ib_write_bw single-path); (b) the specific MR/rkey — failing RCCL write resolved ukey 0xd with kte_va_base=0 (possibly an ANP/CTS special region), whereas ib_write_bw uses a normal buffer MR. `ib_write_bw -x 1/-x 2` loopback both pass → simple IB test does NOT reproduce.

**Workaround INVALID (validated on SMC2 2026-07-28):** `g_disable_p4_loopback=true` does NOT fix it — it converts fast-fail into a HANG. Built a-55+workaround image (tag 1.130.0-a-55 + g_disable_p4_loopback=true), flashed SMC2: IPv6 single-node now TIMES OUT (EXIT=124); qstate shows ud_loopback=0, no key_va_err, but "ack_msn not advancing / messages not being acknowledged / retransmit ring filling / snd_nxt!=snd_una" = requester sent writes, got zero ACKs. Reason: the loopback QPs are SAME-NIC self-writes (QP2<->QP3 on benic1, dmac==own MAC); with ud_loopback off the write egresses to the wire but a switch never hairpins a frame back out its ingress port -> dropped -> no ACK -> hang. IPv4 works only because its dmac is a NON-own MAC (switch forwards normally). So ud_loopback (internal loopback) is ARCHITECTURALLY REQUIRED for same-NIC self-writes; disabling it just changes the failure mode. **The fix must be IN the ud_loopback datapath** (make it correctly service RCCL's multipath/ANP write that trips KT_RANGE_CK), not disabling loopback. IPv4 single-node still passes on the workaround image (19.7 GB/s) as expected.

**Fix area:** the ud_loopback WRITE path (`meta_roce_tx_s5_add_headers_write.p4` loopback branch + `meta_roce_tx_s6.p4` `_common_loopback_headers_dma_cmd_add`; RX `meta_roce_rx_s0.p4:122` skip-dma + VA2PA), specifically its interaction with RCCL multipath / ANP MR. Pin via debug-FW mputrace comparing ib_write_bw (pass) vs RCCL (fail) ud_loopback WRITEs — next step.

**Consequence for testing:** any RCCL config that keeps intra-node loopback (P2P disabled) on a multi-GPU node will hit this over IPv6. Inter-node IPv6 (P2P on, or 1 GPU/node) is unaffected.

**Debug setup left on SMC-1 (2026-07-28):** debug FW `1.130.0-a-74-dirty` flashed on all 8 NICs; `debug_trace=1` added at `meta_roce_rx_s0.p4:82` (responder RX; revert before merge). Build container `pradeept_2026-07-28_*`; vultrace syms + mputrace_ipv{4,6,6_internode}.{bin,decode} in workspace root. Harness `/mnt/clusterfs/karthik/vulcano/hydra_rccl_scripts/` (compute_nodes restored to single-node; IPv6 variants at `/tmp/run-rccl-ipv6*.sh`).
