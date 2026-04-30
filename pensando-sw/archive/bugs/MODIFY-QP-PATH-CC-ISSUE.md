# Modify QP Path Congestion Control Issue - Root Cause Analysis

**Date:** 2026-03-02
**Issue:** Path congestion control parameters not updated on SMC1 firmware 1.125.0-a-133
**Working System:** Waco5 firmware 1.125.1-pi-8

## Executive Summary

SMC1 (firmware 1.125.0-a-133) fails to update per-path congestion control parameters during Modify QP operations, while Waco5 (firmware 1.125.1-pi-8) correctly updates all 8 paths. Root cause is a **code ordering issue** where `qp_set_tp_params()` is called before paths are allocated, causing the path CC update loop to be skipped.

---

## Console Log Comparison

### ✅ Waco5 (Working) - 8 Paths Updated

```
[71:03:34.411,598] lif 48 qid 2 path_qid 0 : Updating path congestion parameters
[71:03:34.411,607] lif 48 qid 2 path_qid 1 : Updating path congestion parameters
[71:03:34.411,609] lif 48 qid 2 path_qid 2 : Updating path congestion parameters
[71:03:34.411,613] lif 48 qid 2 path_qid 3 : Updating path congestion parameters
[71:03:34.411,615] lif 48 qid 2 path_qid 4 : Updating path congestion parameters
[71:03:34.411,619] lif 48 qid 2 path_qid 5 : Updating path congestion parameters
[71:03:34.411,623] lif 48 qid 2 path_qid 6 : Updating path congestion parameters
[71:03:34.411,625] lif 48 qid 2 path_qid 7 : Updating path congestion parameters
[71:03:34.411,646] eth0: RDMA AQ: => qp_id 2 RDMA_UPDATE_QP_OPER_SET_STATE = RTR
```

**Result:** `aq_qp_update_path_cc_params()` called 8 times ✓

### ❌ SMC1 (Not Working) - No Path Updates

```
[01:03:42.683,062] eth0: RDMA AQ: Modify QP - Using default profile
[01:03:42.683,062] eth0: RDMA AQ: Modify QP - Congestion control enabled
[01:03:42.683,064] eth0: RDMA AQ: Modify QP - CC Profile ID 0
[01:03:42.683,066] eth0: RDMA AQ: Modify QP - Path Profile ID 0
[01:03:42.683,068] eth0: qpid: 512, path_qid_base: 4096, num_paths: 1
[01:03:42.683,308] eth0: QP: qp_id 512 allocated retx ring addr 0x4314615808
[01:03:42.683,312] lif 1 qid 512 path_qid 4096 pd_id 1 path_cb_addr 0x100c34000
[01:03:42.683,314] lif 1 qid 512 congestion-control Enabled  <-- Only path creation
[01:03:42.683,320] eth0: RDMA AQ: => qp_id 512 RDMA_UPDATE_QP_OPER_SET_STATE = RTR
```

**Result:** `aq_qp_update_path_cc_params()` **never called** ❌

---

## Root Cause

### Code Flow in admincmd_handler.c

**File:** `nic/rudra/src/hydra/nicmgr/plugin/rdma/admincmd_handler.c`

#### Step 1: Modify QP Debug Log (Line 2529-2537)
```c
NICMGR_TRACE_DEBUG("%s: RDMA AQ: Modify QP AH(handle=%d, dma_addr=0x%lx, "
                   "len=%d, csum=%d, loop=%d, is_ipv6=%d, dscp_offset=%d, "
                   "ah_pa=0x%lx, max_paths=%d, path_qid_base=%d, num_hdrs=%d, "
                   "dest_addr:%s)", eth_lif_name(lif), ah_handle,
                   (long unsigned int)wqe->cmd.mod_qp.dma_addr, ah_len,
                   csum_profile, loopback, is_ipv6, l3_start_offset,
                   (long unsigned int)ah_pa, sqcb1->max_paths,      // <-- max_paths = 0 here!
                   p_sqcb0->path_qid_base, num_ports,
                   (is_ipv6 && !multiplane_qp) ? dest_addr_str : "");
```

**SMC1 Log Output:**
```
[01:03:42.683,060] max_paths=0, path_qid_base=0
```

#### Step 2: qp_set_tp_params() Called (Line 2569)
```c
// setup the required cc params in SQ and path
qp_set_tp_params(lif, qp_id, cc_profile_id, path_profile_id, p_sqcb0, sqcb1);
```

#### Step 3: Inside qp_set_tp_params() (Line 2245-2252)
```c
// update congestion control for path
if (sqcb1->max_paths) {  // <-- max_paths is 0, so this SKIPS!
    uint32_t path_base = p_sqcb0->path_qid_base;
    for (int path_id = 0; path_id < sqcb1->max_paths; ++path_id) {
        aq_qp_update_path_cc_params(lif, qp_id, path_base, cc_profile_id);
        ++path_base;
    }
    qp_setup_sqcb_path_params(cc_profile_id, sqcb1);
}
```

**Result:** Loop is SKIPPED because `sqcb1->max_paths == 0`

#### Step 4: Path Allocation (Line 2628-2655) - AFTER qp_set_tp_params()
```c
if (!sqcb1->max_paths && (attr_mask & (1 << RDMA_UPDATE_QP_OPER_SET_AV))) {
    num_paths = nicmgr_rdma_get_path_count(path_profile_id);
    // ... path allocation ...
    ret = hydra_path_alloc(lif, qp_id, num_paths, &path_base);
    NICMGR_TRACE_DEBUG("%s: qpid: %d, path_qid_base: %u, num_paths: %d",
                       eth_lif_name(lif), qp_id, path_base, num_paths);

    // sqcb1
    sqcb1->max_paths = num_paths;  // <-- max_paths set to 1 HERE, but too late!
    sqcb1->num_ports = num_ports;
    qp_setup_sqcb_path_params(cc_profile_id, sqcb1);

    // Loop to create each path CB
    for (uint32_t i = 0; i < num_paths; i++) {
        eth_rdma_impl_aq_qp_create_path_cb(lif, path_qid, sqcb_pa, rqcb_pa,
                                           qp_id, p_sqcb0->pd, retx_ring_addr, i,
                                           p_sqcb0->cosA, (bool)p_sqcb0->rccl,
                                           p_sqcb0->sack_retx_mode, num_ports,
                                           cc_profile_id, path_profile_id, num_paths);
        path_qid++;
    }
}
```

**SMC1 Log Output:**
```
[01:03:42.683,068] eth0: qpid: 512, path_qid_base: 4096, num_paths: 1
[01:03:42.683,308] eth0: QP: qp_id 512 allocated retx ring addr 0x4314615808
[01:03:42.683,312] lif 1 qid 512 path_qid 4096 congestion-control Enabled
```

---

## The Bug

### Sequence of Events on SMC1:

1. **[Line 2503]** Modify QP debug shows: `max_paths=0, path_qid_base=0`
2. **[Line 2569]** `qp_set_tp_params()` is called
3. **[Line 2245]** Inside qp_set_tp_params(), check `if (sqcb1->max_paths)` **FAILS** (0)
4. **[Line 2247-2250]** Path CC param update loop is **SKIPPED**
5. **[Line 2628-2655]** Paths are allocated and `max_paths` is set to 1
6. **Too late!** qp_set_tp_params() already executed

### Why Waco5 Works:

Waco5 QP 2 has `max_paths = 8` **BEFORE** the Modify QP call.
- Paths were created earlier (during CREATE_QP or previous MODIFY_QP)
- When qp_set_tp_params() runs, max_paths is already 8
- The loop at line 2247 executes and updates all 8 paths

---

## Impact

**Symptoms:**
- RDMA traffic may experience congestion issues
- Path-based load balancing might not work optimally
- Congestion control parameters (DCQCN) not applied to paths
- May cause performance degradation or packet drops under load

**Affected:**
- QPs where paths are allocated during Modify QP to RTR
- Systems running firmware 1.125.0-a-133
- SMC1, SMC2 (confirmed)
- GT1 (likely, same firmware version)

**Not Affected:**
- Waco5, Waco6 (running 1.125.1-pi-8)
- QPs where paths were pre-allocated before Modify QP

---

## The Fix

### Option 1: Call Path CC Update After Path Allocation (Recommended)

After line 2657 (`qp_setup_sqcb_path_params(cc_profile_id, sqcb1);`), add:

```c
// Update congestion control parameters for newly allocated paths
uint32_t path_base_cc = path_base;
for (int path_id = 0; path_id < num_paths; ++path_id) {
    aq_qp_update_path_cc_params(lif, qp_id, path_base_cc, cc_profile_id);
    ++path_base_cc;
}
```

### Option 2: Move qp_set_tp_params() Call

Move line 2569 (`qp_set_tp_params(...)`) to AFTER line 2695 (after all paths are created).

**Risk:** May break other dependencies that expect SQ/RQ CB params to be set earlier.

### Option 3: Pre-allocate Paths During CREATE_QP

Ensure paths are always allocated during CREATE_QP, not deferred to MODIFY_QP.

**Risk:** Larger change, may affect QP creation performance.

---

## Code References

**File:** `nic/rudra/src/hydra/nicmgr/plugin/rdma/admincmd_handler.c`

**Key Functions:**
- `eth_rdma_impl_qp_modify()` - Line 2282
  - Calls `qp_set_tp_params()` at line 2569
  - Allocates paths at line 2628-2696
- `qp_set_tp_params()` - Line 2214
  - Updates SQ/RQ CB CC params
  - Should update path CC params at line 2245-2252 (but skips if max_paths == 0)
- `aq_qp_update_path_cc_params()` - Line 453
  - Updates individual path CB congestion parameters

**Line Number References (current code):**
- 2503: Debug log showing max_paths=0
- 2569: qp_set_tp_params() called (TOO EARLY)
- 2245: Check if (sqcb1->max_paths) - FAILS
- 2247-2250: Path CC update loop - SKIPPED
- 2628: Check if (!sqcb1->max_paths) - TRUE, so allocate paths
- 2655: max_paths = num_paths - SET (TOO LATE)

---

## Firmware Version Information

| System | Firmware Version | Build Tag | Status |
|--------|------------------|-----------|--------|
| SMC1 | 1.125.0-a-133 | 1.XX.0-C-8-50678-g4227316f751d | ❌ Broken |
| SMC2 | 1.125.0-a-133 | 1.XX.0-C-8-50678-g4227316f751d | ❌ Broken |
| Waco5 | 1.125.1-pi-8 | 1.XX.0-C-8-50614-g85930914e403 | ✅ Working |

**Observation:** The line numbers differ between versions:
- SMC1/SMC2: Line 2503, 2523, 2530, 2533, 2535
- Waco5: Line 2534, 2540, 2543 (different numbering suggests code changes)

This suggests firmware 1.125.1 may have fixed this issue.

---

## Verification

To confirm the issue on any system, check the console logs during Modify QP:

```bash
cd ~/dev-notes/pensando-sw
python3 ./scripts/console-mgr.py --setup <setup> --console vulcano --nic ai0 --cmd "dmesg"
```

**Look for:**
1. `Modify QP AH(...max_paths=0...)` - Indicates paths not yet allocated
2. `Congestion control enabled` - CC is enabled globally
3. **Missing:** `Updating path congestion parameters` for path_qid 0-7

**Working system shows:**
1. `Modify QP AH(...max_paths=8...)` - Paths already exist
2. `Congestion control enabled`
3. **Present:** `Updating path congestion parameters` for each path

---

## Test Case

### Create QP and Modify to RTR

```bash
# On the host
# Run RDMA CM test or rccl-tests that creates QPs
# Monitor Vulcano console logs during QP state transitions
```

### Expected Logs (Working):
```
eth0: RDMA AQ: Modify QP - Congestion control enabled
lif X qid Y path_qid 0 : Updating path congestion parameters
lif X qid Y path_qid 1 : Updating path congestion parameters
... (for all paths)
```

### Actual Logs on SMC1 (Broken):
```
eth0: RDMA AQ: Modify QP - Congestion control enabled
lif X qid Y congestion-control Enabled  <-- Only during path creation, no updates
```

---

## Recommended Action

### Immediate Workaround

**Upgrade to firmware 1.125.1 or later** - This version appears to have fixed the issue.

```bash
# Check if 1.125.1 firmware is available
# Update SMC1 and SMC2 to match Waco5 firmware version
```

### Code Fix (If Staying on 1.125.0)

Apply Option 1 fix from above - add explicit path CC update after path allocation.

**Patch Location:** After line 2657 in `admincmd_handler.c`

---

## Related Documentation

- [Firmware Update Procedure](./FIRMWARE-UPDATE-QUICKREF.md)
- [Firmware Partition Switch](./FIRMWARE-PARTITION-SWITCH.md)
- [Hydra Autoclear Behavior](./HYDRA-AUTOCLEAR-BEHAVIOR.md)

---

## Discovered By

Console log analysis comparing working (Waco5) vs non-working (SMC1) systems during Modify QP operations.

**Console Sessions:**
- SMC1 ai0: `/home/pradeept/vulcano-logs/smc1-ai0-console.log`
- Waco5 ai0: `/home/pradeept/vulcano-logs/waco5-ai0-console.log`

**Analysis Date:** 2026-03-02
