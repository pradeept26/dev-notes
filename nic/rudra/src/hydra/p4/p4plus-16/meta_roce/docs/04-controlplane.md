# 04 — Control Plane: nicmgr RDMA Resource Management

This document covers how the nicmgr control plane initializes and manages RDMA
resources that the dataplane P4 pipeline uses. For dataplane CB field tables
read the CB headers in `include/` directly. For how the TX pipeline consumes
these structures see `02-tx-pipeline.md`.

---

## 1. Architecture Overview

```
Host verbs library (libibverbs / librxe)
        |
        | PCIe (ionic driver)
        v
+-------+-------------------+
|  Admin Queue (AQ)         |  ionic_v1_admin_wqe posted to HBM ring
|  Dev Command registers    |  ionic_dev_cmd posted to MMIO bar
+-------+-------------------+
        |
        v (UXDMA pipeline / AQ handler)
+-------+-------------------+
|  nicmgr (firmware)        |
|  EthLifRdma::CmdHandler() |  dev cmds: EQ/CQ/AdminQ create
|  eth_rdma_impl_aq_hdlr()  |  AQ cmds: QP/MR create/modify/destroy
+-------+-------------------+
        |
        | Direct HBM writes (WRITE_MEM / swizzled_copy)
        v
+-------+-------------------------------------------+
| HBM Control Blocks                                 |
| SQCB0 SQCB1 SQCB2  (64B each, contiguous)         |
| RQCB0 RQCB1        (64B each, contiguous)          |
| path_cb0/1/2/3     (4 × 64B per path)              |
| CQ CB (cqcb_t)     (64B)                           |
| AH table (96B/entry)                               |
| Page table (8B/PTE)                                |
| Key table (key_entry_t, 64B/entry)                 |
+-------+-------------------------------------------+
        |
        | (dataplane reads via qstate_addr)
        v
+-------+-------------------+
|  P4+ UXDMA Pipeline       |
|  S0: SQCB0/RQCB0          |
|  S1-S7: path_cb, SQCB1..4 |
+-------+-------------------+
```

**nicmgr** is a firmware component running on the SoC ARM cores. It owns the
control path for the NIC — it processes admin commands from the host, programs
control blocks in HBM, and manages resource allocation. It does **not**
participate in the fast path (packet processing).

Control plane commands reach nicmgr through two channels:

1. **Dev commands** (`ionic_dev_cmd`): posted to a fixed MMIO BAR register.
   Processed synchronously by `EthLifRdma::CmdHandler()`. Used for: EQ create,
   CQ create (dev-command path), AdminQ create, LIF reset.

2. **Admin queue commands** (`ionic_v1_admin_wqe`): posted to a ring in HBM,
   processed by `eth_rdma_impl_aq_hdlr()`. Used for: QP create/modify/destroy,
   MR register/deregister, AH create/destroy, CQ create (AQ path), stats.

---

## 2. Software PHV Injection (Control Plane → Dataplane Feedback)

The nicmgr control plane can inject software-constructed PHVs directly into the UXDMA pipeline to trigger dataplane actions without host involvement. The PHV is injected to the CQ (for completion feedback) or RQ (for active QP updates) depending on the use case.

This mechanism is used for:

- **Completion feedback** (`RDMA_AQ_COMPLETION_FEEDBACK`) - Trigger CQE posting from nicmgr → injected to **CQ**
- **Barrier synchronization** (`RDMA_AQ_NICMGR_BARRIER`) - Control plane synchronization points → injected to **CQ**
- **Active QP updates** (`RDMA_AQ_ACTIVE_QP_UPDATE`) - QP state propagation to dataplane → injected to **RQ**

### 2.1 Feedback Types

Defined in `include/rdma_types.p4`:

```p4
#define RDMA_AQ_FEEDBACK              0x4
#define RDMA_AQ_COMPLETION_FEEDBACK   0x6
#define RDMA_AQ_NICMGR_BARRIER        0x7
#define RDMA_AQ_ACTIVE_QP_UPDATE      0x8
```

### 2.2 PHV Injection Flow

**Completion Feedback / Barrier (CQ injection):**
```
nicmgr constructs rdma_admin_cpl_feedback_t
    ↓ Sets feedback_type = COMPLETION_FEEDBACK | BARRIER
Inject PHV to CQ (TxDMA pipeline)
    ↓
TX S0: rdma_comp_tx_s0_process
    ↓ Checks: comp_rx == 1 && feedback_type in {COMPLETION_FEEDBACK, BARRIER}
    ↓ Calls: generate_feedback() → re-injects to RX with comp_rx=1
RX S0: rdma_comp_rx_s0
    ↓
Post CQE or process barrier
```

**Active QP Update (RQ injection):**
```
nicmgr constructs rdma_admin_cpl_feedback_t
    ↓ Sets feedback_type = ACTIVE_QP_UPDATE
Inject PHV to RQ (TxDMA pipeline)
    ↓
TX S0: resp_tx_rqcb_process
    ↓ Checks: resp_rx_fb == 1 && feedback_type == ACTIVE_QP_UPDATE
    ↓ Calls: generate_feedback() → re-injects to RX with resp_rx_fb=1
RX S0: resp_rx_rqcb_process_feedback
    ↓
Update QP state
```

### 2.3 Code Locations

- **TX handling**: `tx/meta_roce_tx_s0.p4` in `resp_tx_rqcb_process()` (ACTIVE_QP_UPDATE) and `rdma_comp_tx_s0_process()` (COMPLETION_FEEDBACK/BARRIER)
- **RX handling**: `rx/meta_roce_rx_s0.p4` in `resp_rx_rqcb_process_feedback()` (ACTIVE_QP_UPDATE) and `rdma_comp_rx_s0()` (COMPLETION_FEEDBACK)
- **Feedback structure**: `include/rdma_types.p4` (`rdma_admin_cpl_feedback_t`)
- **Nicmgr injection**: `nic/rdma/admincmd_handler.c`

Comments in TX code explicitly note: *"this can only have come about via software PHV insertion from the nicmgr"*

---

## 3. LIF Initialization

### 2.1 Entry point

`rdmamgr_impl::lif_init()` in `rdmamgr_impl.cc`. Called once per LIF on
driver initialization.

Function signature:
```cpp
sdk_ret_t rdmamgr_impl::lif_init(
    uint32_t lif,           // LIF ID
    uint32_t max_keys,      // number of MR keys
    uint32_t max_ahs,       // number of AH entries
    uint32_t max_ptes,      // number of page table entries
    uint64_t mem_bar_addr,  // CMB/bar address (0 = allocate from HBM)
    uint32_t mem_bar_size,  // CMB size in bytes (multiple of 8MB)
    uint32_t max_prefetch_wqes  // RQ prefetch pool size
);
```

### 2.2 Queue state base addresses

The hardware scheduler derives the SQCB/RQCB/CQCB physical address for a
given QID from the LIF table entry. The LIF table is programmed once during
`lif_init` using `p4pd_common_p4plus_txdma_stage0_rdma_params_table_entry_add`:

```cpp
// CQ base
cq_base_addr = lifmgr_lif_qstate_base_addr_get(lm_, lif, Q_TYPE_RDMA_CQ);
sram_lif_entry.cqcb_base_addr_hi = cq_base_addr >> CQCB_ADDR_HI_SHIFT;  // CQCB_ADDR_HI_SHIFT=10
sram_lif_entry.log_num_cq_entries = log2(roundup_to_pow2(max_cqs));

// SQ base
sq_base_addr = lifmgr_lif_qstate_base_addr_get(lm_, lif, Q_TYPE_RDMA_SQ);
sram_lif_entry.sqcb_base_addr_hi = sq_base_addr >> SQCB_ADDR_HI_SHIFT;  // SQCB_ADDR_HI_SHIFT=10

// RQ base
rq_base_addr = lifmgr_lif_qstate_base_addr_get(lm_, lif, Q_TYPE_RDMA_RQ);
sram_lif_entry.rqcb_base_addr_hi = rq_base_addr >> RQCB_ADDR_HI_SHIFT;  // RQCB_ADDR_HI_SHIFT=10
```

The 24-bit `*cb_base_addr_hi` stores bits [33:10] of the HBM base address.
The dataplane shifts this left by 10 to recover the 34-bit address. SQCB size
is `2^RDMA_SQCB_SIZE_SHIFT = 512B` (covers SQCB0+SQCB1+SQCB2+SQCB3+SQCB4).
RQCB size is `2^RDMA_RQCB_SIZE_SHIFT = 256B` (covers RQCB0+RQCB1).

### 2.3 HBM memory regions allocated per LIF

A single contiguous HBM block is allocated for all per-LIF RDMA resources
using `rdma_hbm_allocator_` (label `"rdma"`, 4KB align):

```
Layout (in allocation order):
  [pt_base]          = Page table: 8B * max_ptes (4KB aligned)
  [kt_base]          = MR key table: sizeof(key_entry_t) * max_keys
  [to_base]          = Translate-Only keys: sizeof(key_entry_t) * max_keys
  [dcqcn_base]       = DCQCN profiles: sizeof(dcqcn_config_cb_t) * 8
  [prefetch_cb]      = LIF-level RQ prefetch CB: 4KB (page aligned)
  [prefetch_ring]    = RQ prefetch ring: sizeof(rq_prefetch_ring_t) * 4096
  [prefetch_buf]     = RQ prefetch WQE pool: RQ_PREFETCH_WQE_SIZE * max_prefetch_wqes
  [ah_base]          = AH/header template table: AT_ENTRY_SIZE_BYTES * max_ahs (96B/entry)
  [mem_bar/barmap]   = CMB (controller memory buffer for SQ/RQ in HBM)
```

HBM page table and key table base addresses are recorded in `sram_lif_entry`
as 22-bit page IDs (right-shift 12 bits).

### 2.4 Path CB (path_lif2qstate) base

Path CBs are allocated from a **separate** HBM region labeled
`"meta_roce"` / `JHYDRA_PATH_LIF2QSTATE_MAP_NAME`:

```cpp
// eth_lif_rdma.cc, EthLifRdma constructor:
g_path_qstate_base = api::g_pds_state.mempartition()->start_addr(
                         JHYDRA_PATH_LIF2QSTATE_MAP_NAME);
meta_roce_region = mem_allocator_get_region(JMETA_ROCE_REGION_NAME);
path_bmap = new BMAllocator(RUDRA_HYDRA_PATH_LIF_NUM_QUEUES);
```

Global `g_path_qstate_base` is fixed at system boot. Individual path CB
addresses are computed as:
```cpp
uint64_t path_qstate_addr(uint32_t qid) {
    return g_path_qstate_base + qid * PATH_QSTATE_SIZE;
}
// PATH_QSTATE_SIZE = 64 << META_ROCE_PATH_CB_SIZE_SHIFT = 4 × 64B = 256B
```

Path QIDs are allocated from `path_bmap` (a bit-map allocator over
`RUDRA_HYDRA_PATH_LIF_NUM_QUEUES` total path slots).

### 2.5 Scheduler and doorbell configuration

The LIF table entry (`sram_lif_entry_t`) encodes the queue type values:
```cpp
sram_lif_entry.sq_qtype = Q_TYPE_RDMA_SQ;   // ETH_HW_QTYPE_SQ
sram_lif_entry.rq_qtype = Q_TYPE_RDMA_RQ;   // ETH_HW_QTYPE_RQ
sram_lif_entry.aq_qtype = Q_TYPE_ADMINQ;    // ETH_HW_QTYPE_ADMIN
sram_lif_entry.rdma_en_qtype_mask =
    (1<<Q_TYPE_RDMA_SQ)|(1<<Q_TYPE_RDMA_RQ)|
    (1<<Q_TYPE_RDMA_CQ)|(1<<Q_TYPE_RDMA_EQ)|(1<<Q_TYPE_ADMINQ);
```

This mask tells the scheduler which queue types are RDMA-enabled for this LIF.
CQs and EQs do not drive the scheduler directly (they are completion queues);
only SQ, RQ, and AQ have scheduler rings.

---

## 3. QP Create Flow

### 3.1 Admin command path

The host posts an `ionic_v1_admin_wqe` with opcode `IONIC_V1_AQ_OP_CREATE_QP`
to the admin queue ring in HBM. The UXDMA pipeline detects the new WQE,
processes it, and calls `eth_rdma_impl_aq_qp_create_hdlr()`, which then calls
`rdma_handle_create_qp()` in `eth_lif_rdma.cc`.

Command structure used: `wqe->cmd.create_qp` (type `ionic_v1_admin_create_qp_cmd`).

### 3.2 Path QID allocation

Before programming CBs, nicmgr allocates path QIDs:
```cpp
uint32_t path_qid = path_bmap->Alloc(num_paths);  // contiguous range
```

`num_paths` is the number of paths for this QP (from the create_qp command).

### 3.3 SQCB0 programming

`SQCB0` is the 64B block at `sqcb_pa`. Written as a raw byte array with
`swizzled_copy` (bit-reversal within each byte, accounting for little-endian
hardware layout):

| Field | Value | Notes |
|-------|-------|-------|
| `action_id` | `sq_action_id` | PC offset for S0 SQCB handler |
| `total` | `MAX_SQ_TOTAL_RINGS = 1` | Scheduler ring count |
| `host` | `SQ_HOST_RING = 1` | Host ring count |
| `pid` | `cpu_to_be16(wqe->cmd.create_qp.dbid_flags)` | Doorbell ID |
| `pd` | `wqe->cmd.create_qp.pd_id` | Protection domain |
| `lg2_wqe_sz` | `wqe->cmd.create_qp.sq_stride_log2` | WQE size (log2) |
| `lg2_sq_ring_sz` | `wqe->cmd.create_qp.sq_depth_log2` | SQ depth (log2) |
| `path_cb_base_addr` | `path_qstate_addr(path_qid)` | Base of path CB array |
| `path_qid_base` | `path_qid` | First path QID |
| `path_lif` | `RUDRA_HYDRA_PATH_LIF` | LIF for path doorbells |
| `va2pa_key` | `sq_va2pa_key` | Key for SQ buffer VA→PA |
| `msn` | `0x1` | Initial MSN |
| `lsn_rx` | `msn + 0x7d` | Initial local SN receive limit |
| `sq_on_host` | `sq_on_host` | Flag: SQ WQEs in host memory |
| `wqe_ring_base` | `expdb_wqe_ring_base` | (if `expdb_en`) Explicit doorbell WQE ring |

### 3.4 SQCB1 programming

`SQCB1` is at `sqcb_pa + 64`. Key fields:

| Field | Value | Notes |
|-------|-------|-------|
| `max_paths` | `num_paths` | Total paths for this QP |
| `path_bitmap[7:0]` | `(1 << num_paths) - 1` | All paths initially active |
| `max_pkts_on_path` | `4` | Max burst per path before round-robin |
| `path_cb_base_addr` | `path_qstate_addr(path_qid)` | Same as SQCB0 |
| `lg2_sq_ring_sz` | `wqe->cmd.create_qp.sq_depth_log2` | |
| `sq_bmsn` | `0x1` | Base MSN for bitmap tracking |
| `exp_sq_msn` | `0x1` | Expected next TX MSN |
| `cqcb_base_addr` | `sq_cqcb_pa` | SQ completion CQ |

Note: `max_paths` up to 64 is stored in the lower 64 bits of `path_bitmap`.
Paths 64–95 would use `path_bitmap[MAX_PATH_ID:64]` but are noted as TODO
in the code.

CC parameters (`epsilon`, `log_beta`, `log_lambda`, `gamma`, `omega`, `rcn`,
`qwnd_min`, etc.) are **not** set at QP create time. They are set by QP
modify or by a separate `modify_dcqcn` admin command. Default values of zero
mean: no AIMD (AI=0, MD=no-op), no RCN, no congestion management.

To enable congestion management, `congestion_mgmt` in SQCB0 must be set to 1
via a modify command.

### 3.5 SQCB2 programming

`SQCB2` is at `sqcb_pa + 128`:

| Field | Value | Notes |
|-------|-------|-------|
| `cqcb_base_addr` | `sq_cqcb_pa` | CQ for send completions |
| `path_qid_base` | `path_qid` | |
| `bmsn` | `0x1` | Base MSN |
| `ack_msn` | `0` | Last acknowledged MSN (advanced by RX pipeline) |

`header_template_addr` and `tfp_csum_profile` in SQCB2 are **not** set at
QP create. They are set during **QP modify** when the address vector (AH) is
attached.

### 3.6 RQCB0 programming

`RQCB0` is at `rqcb_pa`:

| Field | Value | Notes |
|-------|-------|-------|
| `action_id` | `rq_action_id` | PC offset for S0 RQCB handler |
| `total` | `MAX_RQ_HOST_RINGS = 2` | |
| `host` | `RQ_HOST_RING = 1` | |
| `pid` | `cpu_to_be16(wqe->cmd.create_qp.dbid_flags)` | |
| `cqcb_base_addr` | `rq_cqcb_pa` | RQ completion CQ |
| `path_cb_base_addr` | `path_qstate_addr(path_qid)` | |
| `path_qid_base` | `path_qid` | |
| `path_lif` | `RUDRA_HYDRA_PATH_LIF` | |
| `lg2_rq_ring_sz` | `wqe->cmd.create_qp.rq_depth_log2` | |
| `lg2_rq_wqe_sz` | `wqe->cmd.create_qp.rq_stride_log2` | |
| `lg2_mtu` | `12` | Default MTU = 4096B (4KB) |
| `max_csn` | `0xff` | Max concurrent sequence numbers |

`state` is left as 0 (RESET) at create time. It advances to INIT/RTR/RTS
via modify.

### 3.7 RQCB1 programming

`RQCB1` is at `rqcb_pa + 64`:

| Field | Value | Notes |
|-------|-------|-------|
| `msn_queue_base_addr` | `msn_queue_base_addr` | Per-MSN context ring in HBM |
| `bmsn` | `0x1` | Base MSN |
| `rnr_timeout` | `META_ROCE_RNR_TIMEOUT = 2` | Default RNR code: 5µs × 2^2 = 20µs |
| `rcq_base_addr` | `rq_location` | RCQ (receive completion queue) base |

### 3.8 path_cb initialization

`rdma_handle_create_path_cb()` is called for each path. It writes four 64B
blocks at `path_qstate_addr(path_qid) + {0, 64, 128, 192}`.

**path_cb0** (64B at offset 0):

| Field | Value | Notes |
|-------|-------|-------|
| `action_id` | `path_action_id` | PC offset for S0 path handler |
| `total` | `4` | 4 scheduler rings: SQ, retx, SACK, ACK/NAK |
| `rdma_sqcb_addr` | `sqcb_pa` | Back-pointer to SQCB for TX use |
| `rdma_rqcb_addr` | `rqcb_pa` | Back-pointer to RQCB |
| `rdma_lif` | `lif_id` | LIF for completions |
| `rdma_qid` | `qid` | QP QID |
| `pd` | `pd_id` | Protection domain |

**path_cb1** (64B at offset 64):

| Field | Value | Notes |
|-------|-------|-------|
| `rcv_nxt` | `0` | Next expected receive FSN |
| `max_fsn` | `0xFFFF` | Max FSN seen (initialized to max to avoid false OOO) |

All other fields in path_cb1 default to 0: `rsp_rx_epoch`, `rsp_tx_epoch`,
`send_ack_pi`, `ack_cfsn`, `fsn_bitmap`, `rnr_bitmap`, `tx_entropy_sport`,
`nak_prune`.

**path_cb2** (64B at offset 128):

| Field | Value | Notes |
|-------|-------|-------|
| `cwnd` | `30000` | Initial path window (very large: effectively unlimited) |
| `retx_ring_addr` | `retx_ring_addr` | Retransmit ring in HBM |
| `lg2_retx_ring_sz` | `8` | 256-entry retx ring |
| `entropy_sport` | `g_path_sport` | UDP source port (entropy) for this path |
| `max_ack_fsn` | `0xFFFF` | Max ACK FSN seen |

`g_path_sport` is a global counter starting at `PATH_SPORT_START = 49152`,
incremented per path to ensure per-path entropy differentiation.

Other path_cb2 fields defaulting to 0: `snd_una`, `snd_nxt`, `rto`,
`rtt_p`, `rtt_mdev`, `alpha_p_shift`, `beta_shift`, `rnr_timeout` (0 =
`RNR_TIMEOUT_INVALID`), `snd_inflate`, `rnr_retx_bmap`, `retx_ci`.

**path_cb3** (64B at offset 192):

All fields default to 0: `cwnd` (separate from cb2.cwnd, used for SACK
snd\_inflate tracking), `snd_una`, `fsn_bitmap`, `current_rtt`,
`last_snd_inflate`, `last_inflate_fsn`, `num_sack_retx_tx`,
`num_sack_retx_rx`.

---

## 4. QP Modify Flow

### 4.1 Admin command

`ionic_v1_admin_wqe` with opcode `IONIC_V1_AQ_OP_MODIFY_QP`.
Handler: `eth_rdma_impl_aq_qp_modify_hdlr()` → `rdma_handle_modify_qp()`.

The command carries a 32-bit `attr_mask` bitmask. Only set bits cause updates.

### 4.2 State transitions

QP state is encoded in `SQCB0.state` and `RQCB0.state`:

| QP state | `RDMA_QP_STATE_*` value | Allowed operations |
|----------|------------------------|-------------------|
| RESET (0) | `QP_STATE_RESET = 0` | None (dataplane drops all) |
| INIT (1) | `QP_STATE_INIT = 1` | Configured but not yet active |
| RTR (3) | `QP_STATE_RTR = 3` | Responder active (RX data accepted) |
| RTS (4) | `QP_STATE_RTS = 4` | Both TX and RX fully active |
| ERR (2) | `QP_STATE_ERR = 2` | Error state; drops all traffic |

Transitions are set via `attr_mask & (1 << RDMA_UPDATE_QP_OPER_SET_STATE)`.
nicmgr writes the new state to `SQCB0.state` and `RQCB0.state` directly.
The dataplane guards:
- S0 SQCB (requester TX): `if (d.state != RDMA_QP_STATE_RTS) drop`.
- S0 RQCB (responder RX): `if (d.state < RDMA_QP_STATE_RTR) drop`.

### 4.3 Path MTU

```cpp
if (attr_mask & (1 << RDMA_UPDATE_QP_OPER_SET_PATH_MTU)) {
    p_sqcb0->lg2_pmtu = wqe->cmd.mod_qp.pmtu;  // log2 of MTU in bytes
    p_rqcb0->lg2_mtu = wqe->cmd.mod_qp.pmtu;
}
```

### 4.4 Destination QP number

```cpp
if (attr_mask & (1 << RDMA_UPDATE_QP_OPER_SET_DEST_QPN)) {
    sqcb2.dst_qp = wqe->cmd.mod_qp.qkey_dest_qpn;
}
```

`sqcb2.dst_qp` is embedded in the TX packet by the dataplane as the RDMA
destination QPN in the BTH.

### 4.5 Address vector (AV) and header template

```cpp
if (attr_mask & (1 << RDMA_UPDATE_QP_OPER_SET_AV)) {
    uint32_t ah_handle = wqe->cmd.mod_qp.ah_id_len & 0xffffff;
    uint8_t ah_len = wqe->cmd.mod_qp.ah_id_len >> 24;
    uint8_t csum_profile = wqe->cmd.mod_qp.tfp_csum_profile;
    uint64_t ah_pa = ah_pa_base + (ah_handle * AT_ENTRY_SIZE_BYTES);  // AT_ENTRY_SIZE_BYTES=96

    // DMA the pre-built header template from host to HBM AH entry
    edma_cb(user_data, wqe->cmd.mod_qp.dma_addr, lif_id, ah_pa, false, ah_len);

    // Write size and csum_profile after the template data
    WRITE_MEM(size_pa, &ah_len, sizeof(ah_len), 0);
    WRITE_MEM(size_pa + sizeof(ah_len), &csum_profile, sizeof(csum_profile), 0);

    sqcb2.header_template_addr = (uint32_t)(ah_pa >> 3);  // byte addr >> 3 = 8B-word addr
    sqcb2.header_template_size = ah_len;
    sqcb2.tfp_csum_profile = csum_profile;
}
```

The AH entry in HBM is `AT_ENTRY_SIZE_BYTES = 96B`:
- Bytes [0, HDR_TEMPLATE_T_MAX_SIZE_BYTES): the pre-built Eth+IP+UDP header
  (max 80B).
- Bytes [80]: `template_nbytes` (actual length).
- Bytes [81]: `csum_profile:4 | loopback:1 | rsvd:3`.

### 4.6 CC parameter programming

CC parameters are **not** programmed by `modify_qp`. They are programmed by
a separate `modify_dcqcn` admin command (`IONIC_V1_AQ_OP_MODIFY_DCQCN`),
handled by `eth_rdma_impl_aq_modify_dcqcn_hdlr()`. This writes directly to
`rdma_sqcb1_t` (at `sqcb_pa + 64`):

```
SQCB1 CC fields set by modify_dcqcn:
  epsilon          — AI increment (dimensionless, per-packet)
  log_beta         — MD shift for CNP (1/2^log_beta per CNP)
  log_lambda       — MD shift for SACK loss (1/2^log_lambda per hole)
  gamma            — Q8.8 scale factor for RCN rate→cwnd conversion
  omega            — RTT inflation offset (in 8×µs units, added to rtt_qp)
  rcn              — RCN mode enable (1 = use rate_hints from peer)
  rcn_use_min_rtt  — Use min(rtt_min, rtt_qp)/2 for RCN
  qwnd_min         — Minimum QWND (in packets)
  rcn_pwnd_min     — Minimum PWND under RCN (in packets)
  exact_cwnd_enforce — Enable exact window enforcement
  log_pwnd_max     — log2 of per-path max window
  congestion_mgmt  — Master enable for S2 CC processing
  sack_retx_mode   — SACK_RETX_MODE_DISABLE / SACK_RETX_MODE_SELECTIVE
```

Default values at QP create: all zero. CC is effectively disabled until
`congestion_mgmt = 1` is set, because S0 gates S2 with
`pred.congestion_mgmt = d.congestion_mgmt`.

---

## 5. MR Registration Flow

### 5.1 Admin command

`ionic_v1_admin_wqe` with opcode `IONIC_V1_AQ_OP_REG_MR`.
Handler: `eth_rdma_impl_aq_mr_create_hdlr()`.

### 5.2 Key generation

The 32-bit lkey/rkey has two parts:
```cpp
struct rdma_key_t {
    uint32_t ukey    :  8;  // user-visible key (randomized per registration)
    uint32_t kte_idx : 24;  // index into key table
};
```

`kte_idx` is allocated from the per-LIF key table. `ukey` is a 8-bit
random value chosen by the driver to prevent key guessing attacks. The
dataplane checks `mr_ukey` against the key presented in the packet.

### 5.3 Page table construction

PTEs are written to the page table at `pt_base + kte_idx * 8B_per_pte`.
Each PTE is 8 bytes encoding the physical address of a 4KB (or 2MB/1GB) page.

```cpp
uint64_t eth_rdma_impl_aq_pte_write(eth_lif_t *lif, uint64_t pa_offset,
    uint64_t region_size, enum va2pa_key_pt_type pt_type,
    uint64_t dma_addr, uint32_t page_size, uint32_t count);
```

The driver provides the DMA address of a host-side array of PTEs. nicmgr
uses EDMA (`edma_copy`) to DMA these from the host to HBM in 512-PTE chunks
(`pt_chunk_size = 512`).

In SIM mode (`ASSUME_PHYS_CONTIG_PTES = 1`), only the first PTE is
transferred and the rest are computed as `pa[0] + i * page_size`.

### 5.4 key_entry_t programming

`key_entry_t` is 64B in HBM at `kt_base + kte_idx * sizeof(key_entry_t)`:

| Field | Content |
|-------|---------|
| `phy_base_addr` | Physical base address (for contig MRs) |
| `pt_base` | PT entry offset for this MR |
| `base_va` | Virtual address of MR start |
| `len` | MR length in bytes |
| `log_page_size` | log2 of page size (12=4KB, 21=2MB, 30=1GB) |
| `acc_ctrl` | Access flags: local_write, remote_write, remote_read, atomic |
| `pd` | Protection domain |
| `mr_l_key` | Local key (lkey) |
| `user_key` | ukey (8-bit random) |
| `type` | MR_TYPE_MR, MR_TYPE_MW_TYPE_1, etc. |
| `state` | Valid / invalid |
| `flags` | `mr_flags_privileged`, `mr_flags_window`, `mr_flags_invalidate` |
| `host_addr` | 1 = host memory, 0 = device memory |

`eth_rdma_aq_kte_write()` writes the `key_entry_t` to HBM and invalidates
the P4+ cache for that address range.

### 5.5 Access flags

Stored in `acc_ctrl` byte:
- Bit 0: local write
- Bit 1: remote write
- Bit 2: remote read
- Bit 3: atomic

The dataplane checks these at packet receive time (S4, `resp_rx_rdma_rqsge0`)
using `probe.pages.rdma.mr_access_local_write` and
`probe.pages.rdma.mr_access_remote_write`.

---

## 6. QP Destroy Flow

### 6.1 Admin command

`ionic_v1_admin_wqe` with opcode `IONIC_V1_AQ_OP_DESTROY_QP`.
Handler: `eth_rdma_impl_aq_qp_destroy_hdlr()` → `rdma_handle_destroy_qp()`.

### 6.2 Drain sequence

No explicit drain is implemented in the current code. The destroy handler
immediately proceeds to teardown. The caller (verbs library) is responsible
for draining the QP before calling destroy (standard RDMA protocol).

### 6.3 CB teardown order

```cpp
int rdma_handle_destroy_qp(lif_id, wqe, sqcb_pa, path_bmap, meta_roce_region) {
    // 1. Zero the PC byte of SQCB0 (disables S0 dispatch)
    WRITE_MEM(sqcb_pa, sqcb0_zero, 1, 0);

    // 2. Read current SQCB0 and SQCB1 to get path info
    READ_MEM(sqcb_pa, sqcb0, 64, 0);
    READ_MEM(sqcb_pa + 64, sqcb1, 64, 0);
    num_paths = sqcb1.max_paths;
    path_qid_base = sqcb0.path_qid_base;

    // 3. Destroy each path CB (free retx ring)
    for (i = path_qid_base; i < path_qid_base + num_paths; i++) {
        rdma_handle_destroy_path_qp(meta_roce_region, lif_id, i);
    }

    // 4. Free path QIDs back to allocator
    path_bmap->Free(path_qid_base, num_paths);
}
```

`rdma_handle_destroy_path_qp()` reads `path_cb2` to get `retx_ring_addr`
and frees it:
```cpp
void rdma_handle_destroy_path_qp(meta_roce_region, lif_id, path_qid) {
    READ_MEM(path_cb_addr + 128, path_cb2, 64, 0);
    mem_allocator_free(meta_roce_region, path_cb2.retx_ring_addr);
}
```

The retx ring is the only HBM allocation within a path CB that is tracked
separately (all other path CB memory is pre-allocated as part of the
`JHYDRA_PATH_LIF2QSTATE_MAP_NAME` region).

### 6.4 LIF reset

`eth_rdma_impl_lif_reset_hdlr()` (via `IONIC_CMD_RDMA_RESET_LIF`) zeros
the PC byte of all SQ, RQ, CQ, and AQ queue states and invalidates the
P4+ cache. This effectively disables all RDMA processing for the LIF.
Additionally, the key table is zeroed to invalidate all MR registrations.

---

## 7. Header Template Construction

### 7.1 Format

The pre-built Eth+IP+UDP header template is stored in HBM at the AH entry
address. It is up to `HDR_TEMPLATE_T_MAX_SIZE_BYTES = 80B` of header data,
followed by 2 bytes of metadata at offset 80:

```
[0 .. ah_len-1]    : raw Eth+VLAN+IP+UDP bytes (exactly ah_len bytes)
[80]               : template_nbytes (= ah_len, stored by nicmgr)
[81]               : csum_profile:4 | loopback:1 | rsvd:3
```

`sqcb2.header_template_addr` stores `ah_pa >> 3` (8-byte word address).
`sqcb2.header_template_size` stores `ah_len` in bytes.

### 7.2 Template content

The template is constructed by the driver (verbs library) and DMA'd to nicmgr
during `create_ah` (for standalone AH objects) or `modify_qp` (when the AH
is embedded in the modify command). nicmgr does not build the template itself —
it accepts the pre-built bytes and copies them verbatim to HBM.

The driver fills:

| Offset | Field | Value |
|--------|-------|-------|
| 0 | Dst MAC [6B] | From address vector `dgid` resolved via ARP/ND |
| 6 | Src MAC [6B] | From LIF MAC address |
| 12 | EtherType [2B] | `0x0800` (IPv4) or `0x86DD` (IPv6) |
| (opt) 12 | VLAN tag [4B] | `0x8100` + VID if VLAN is needed |
| 14/18 | IP header [20B IPv4 / 40B IPv6] | TTL=64, DSCP from AV |
| 34/54 | UDP header [8B] | dport=4791, sport=entropy, checksum=0 |

Total template size: 42B (IPv4, no VLAN), 46B (IPv4 + VLAN), 62B (IPv6,
no VLAN), 66B (IPv6 + VLAN).

### 7.3 UDP destination port

Always `4791` (IANA RoCEv2 port). Set by the driver in the template.

### 7.4 UDP source port (entropy)

The initial UDP source port stored in the template is `g_path_sport`
(ranging from `PATH_SPORT_START = 49152` upward). This provides per-path
entropy for ECMP hashing. The TX pipeline may further modify the UDP source
port using `d.tx_entropy_sport` from `path_cb1_t` (updated by RX pipeline
when the peer's UDP source port changes).

### 7.5 IPv4 vs IPv6

The driver chooses template length; nicmgr uses `ah_len` to determine the
format. No separate IPv4/IPv6 flag exists in the CB — the TX pipeline uses
`sqcb2.header_template_size` and the raw bytes.

### 7.6 VLAN tag insertion

The driver inserts the VLAN tag into the template bytes if VLAN is required.
nicmgr stores the template verbatim — no VLAN insertion logic exists in the
firmware.

### 7.7 TFP checksum profile

`sqcb2.tfp_csum_profile` is a 4-bit field specifying which checksum offload
profile the TFP (Transport Framing Processor) should apply when sending
packets. The profile determines whether the hardware computes UDP, IP, or
Ethernet checksums. The value is set from `wqe->cmd.mod_qp.tfp_csum_profile`
during QP modify. Selection logic is entirely driver-side.

### 7.8 ACKDSCP

An additional 2B ACKDSCP value is stored at offset `HDR_TEMPLATE_T_ACK_DSCP_OFFSET = 80`
within the same AH entry. This is used by the TX ACK/NAK path to apply
the correct DSCP marking to outbound ACK packets.

---

## 8. Doorbell and Scheduler

### 8.1 SQ doorbell (host-driven)

The host writes a 64-bit doorbell value to the LIF BAR at the doorbell
register address. The Doorbell Unit (DBU) on the ASIC decodes this write
and posts a scheduler event for the corresponding (LIF, qtype, qid, ring).

The SQ doorbell ring is ring 0 (`SQ_HOST_RING = 1`, index 0 from the
scheduler's perspective). The SQCB0 `total = 1` means there is 1 ring to
schedule.

### 8.2 Path TX doorbell (RX pipeline driven)

The RX pipeline doorbells the path TX queue directly via:
```p4
__ring_doorbell(path_lif, META_ROCE_PATH_QTYPE, path_qid,
                META_ROCE_TX_ACK_NAK_RING,
                doorbell_set_pindex, doorbell_sched_eval, send_ack_pi);
```

The path CB has `total = 4` rings:
- Ring 0: SQ ring (TX sends)
- Ring 1: Retransmit ring (retx triggered by timer)
- Ring 2: SACK retransmit ring (`META_ROCE_TX_RETX_SACK_RING`)
- Ring 3: ACK/NAK ring (`META_ROCE_TX_ACK_NAK_RING`)

`doorbell_sched_eval` causes the scheduler to evaluate whether the queue
should be scheduled (i.e., whether PI > CI). `doorbell_set_pindex` sets
the PI to the specified value rather than incrementing.

### 8.3 Priority configuration

The AQ queue uses `cosA = cosB = asicpd_admin_cos()` for scheduling priority.
RDMA SQ, RQ, and path queues use the default priority assigned by the
scheduler configuration. No explicit priority override is applied by nicmgr
in the CB programming.

---

## 9. Error Recovery (Control Plane Role)

### 9.1 QP error state notification

When the dataplane encounters a fatal error (remote access error, remote
operation error, etc.), it sets `p.comp.err_disable_qp = 1` in the PHV.
In S7 (`req_rx_stats_process` or `resp_rx_stats_process`), the error handler
writes:

```c
// Set error bit at the known offset in SQCB
__table_write_indirect(p.comp.qp_err_dis_offset, 0, 1w1);

// Set QP state to ERR in SQCB0 and SQCB2
__memory_write_b(sqcb0_addr + state_offset, RDMA_QP_STATE_ERR);
__memory_write_b(sqcb2_addr + state_offset, RDMA_QP_STATE_ERR);

// Issue phvfence to ensure writes complete before any further processing
__phvfence();
```

There is no interrupt or signal to nicmgr from the dataplane. The error is
discovered by the host driver when it polls the CQ and sees an error CQE
(generated in S5/S6 of the RX pipeline). The host verbs library then calls
`ibv_poll_cq()`, detects the error CQE, and the application handles it.

### 9.2 QP reset procedure

To reset an errored QP, the verbs library issues a `modify_qp` command with
the target state = RESET. nicmgr:

1. Reads current SQCB0 state.
2. Writes `state = QP_STATE_RESET` to SQCB0 and RQCB0.
3. Clears `err_disable_qp` bit.
4. Resets sequence numbers (`msn = 1`, `lsn_rx`, `snd_una`, etc.) as
   directed by the modify mask.

For a full teardown-and-recreate cycle, the application calls
`ibv_destroy_qp()` followed by `ibv_create_qp()`. nicmgr handles both
commands as described in sections 3 and 6 above.

### 9.3 Error CQE format

When `err_disable_qp == 1`, S5 fills the CQE before S7 disables the QP:

```c
// req_rx_msn_comp_bitmap (S5):
p.comp.cqe.info.send.msn = (bit<32>)p.meta_roce_hdr.saeth.cdmsn;
p.comp.cqe.type = RDMA_CQE_TYPE_SEND_MSN;
p.comp.cqe.err = 1;
p.comp.cqe.status_length = (bit<32>)p.comp.status;  // error code
```

The CQE error status values (`RDMA_CQ_STATUS_REMOTE_ACC_ERR`,
`RDMA_CQ_STATUS_REMOTE_OPER_ERR`, `RDMA_CQ_STATUS_LOCAL_PROT_ERR`, etc.)
map to the IB spec error codes returned to the verbs layer via
`ibv_poll_cq()`.

### 9.4 LIF-level reset

`hydra_rdma_local_state_reset()` and `eth_rdma_impl_lif_reset_hdlr()` are
called by `IONIC_CMD_RDMA_RESET_LIF`. This provides a fast path for the driver
to recover from catastrophic errors without going through individual QP
teardowns. It zeroes all SQ/RQ/CQ/AQ qstates and the key table, but does
**not** free HBM allocations (those remain for re-use on the next LIF init).
