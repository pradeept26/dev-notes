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

**Why:** For ud_loopback=1, TX builds a stripped packet (no BTH): `meta_roce_tx_s5_add_headers_write.p4:170` → `_meta_roce_write_loopback_header()` + `_meta_roce_write_common_loopback_dma_cmd_add()` (DMAs METH only). RX (`meta_roce_rx_s0.p4:122`) does `_resp_rx_set_skip_dma()` then VA2PA on `reth.va + (meth.posn<<mtu)` with `reth.rkey`. Suspected **TX-side** bug: loopback packet assembly assumes 42B (IPv4) template offsets, so with 62B IPv6 the responder resolves a wrong RETH VA/rkey → out-of-MR → KT_RANGE_CK.

**Fix area:** `nic/rudra/src/hydra/p4/p4plus-16/meta_roce/tx/meta_roce_tx_s5_add_headers_write.p4` (and the send equivalent `_add_headers_send.p4`) ud_loopback branch; verify against 62B vs 42B `header_template_size`. Also check nicmgr header-template construction for loopback QPs.

**Consequence for testing:** any RCCL config that keeps intra-node loopback (P2P disabled) on a multi-GPU node will hit this over IPv6. Inter-node IPv6 (P2P on, or 1 GPU/node) is unaffected.

**Debug setup left on SMC-1 (2026-07-28):** debug FW `1.130.0-a-74-dirty` flashed on all 8 NICs; `debug_trace=1` added at `meta_roce_rx_s0.p4:82` (responder RX; revert before merge). Build container `pradeept_2026-07-28_*`; vultrace syms + mputrace_ipv{4,6,6_internode}.{bin,decode} in workspace root. Harness `/mnt/clusterfs/karthik/vulcano/hydra_rccl_scripts/` (compute_nodes restored to single-node; IPv6 variants at `/tmp/run-rccl-ipv6*.sh`).
