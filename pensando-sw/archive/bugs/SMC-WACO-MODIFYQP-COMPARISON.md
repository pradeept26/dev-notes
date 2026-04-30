# SMC1 vs Waco5 Modify QP Comparison - Code Difference Analysis

**Date:** 2026-03-02
**Issue:** `eth_rdma_impl_aq_qp_update_path_cos()` not called on SMC1 (1.125.0-a-133) but called on Waco5 (1.125.1-pi-8)

---

## Critical Finding

### The Missing Function Call

**Function:** `eth_rdma_impl_aq_qp_update_path_cos()`
**Location:** Line 2613 in `admincmd_handler.c`
**Purpose:** Updates path CoS (Class of Service) and autoclear settings

**Waco5 (1.125.1-pi-8):** ✅ Function IS called for all 8 paths
**SMC1 (1.125.0-a-133):** ❌ Function is NEVER called

---

## Evidence from Console Logs

### ✅ Waco5 - Function Called

Log shows explicit function execution:
```
[71:03:34.411,603] lif 48 qid 2 path_qid 0 : Updating path congestion parameters
[71:03:34.411,607] lif 48 qid 2 path_qid 1 : Updating path congestion parameters
[71:03:34.411,609] lif 48 qid 2 path_qid 2 : Updating path congestion parameters
[71:03:34.411,613] lif 48 qid 2 path_qid 3 : Updating path congestion parameters
[71:03:34.411,615] lif 48 qid 2 path_qid 4 : Updating path congestion parameters
[71:03:34.411,619] lif 48 qid 2 path_qid 5 : Updating path congestion parameters
[71:03:34.411,623] lif 48 qid 2 path_qid 6 : Updating path congestion parameters
[71:03:34.411,625] lif 48 qid 2 path_qid 7 : Updating path congestion parameters
```

These logs come from `aq_qp_update_path_cc_params()` line 463:
```c
NICMGR_TRACE_INFO("lif %d qid %d path_qid %d : Updating path congestion parameters",
                  eth_lif_id(lif), qp_id, path_qid);
```

### ❌ SMC1 - Function NOT Called

**Test 1 (1 path):**
- No "Updating path congestion parameters" logs
- Only shows path creation: `lif 1 qid 512 congestion-control Enabled`

**Test 2 (8 paths):**
- Path count updated: `path-count updated from 1 to 8`
- 8 paths created (4096-4103)
- Still NO "Updating path congestion parameters" logs
- Still NO path CoS update logs

**Proof:** These are INFO level logs that ALWAYS appear when functions execute. Their absence confirms the functions were never called.

---

## Code Analysis

### The Two Loops That Should Execute

**Loop 1: Update Path CoS (Line 2611-2615)**
```c
uint32_t path_base = p_sqcb0->path_qid_base;
for (int path_id = 0; path_id < sqcb1->max_paths; ++path_id) {
    eth_rdma_impl_aq_qp_update_path_cos(lif, path_base, cos, ack_cos, (bool)p_sqcb0->rccl);
    ++path_base;
}
```

**Condition:** Requires `cos != -1` (line 2576) AND `sqcb1->max_paths > 0`

**Loop 2: Update Path CC Params (Line 2247-2250 inside qp_set_tp_params)**
```c
if (sqcb1->max_paths) {
    uint32_t path_base = p_sqcb0->path_qid_base;
    for (int path_id = 0; path_id < sqcb1->max_paths; ++path_id) {
        aq_qp_update_path_cc_params(lif, qp_id, path_base, cc_profile_id);
        ++path_base;
    }
    qp_setup_sqcb_path_params(cc_profile_id, sqcb1);
}
```

**Condition:** Requires `sqcb1->max_paths > 0`

---

## Why Both Loops Are Skipped on SMC1

### Hypothesis: Paths Allocated AFTER These Loops Execute

**Code Flow:**
1. Line 2569: `qp_set_tp_params()` called → Loop 2 executes (or skips if max_paths==0)
2. Line 2576-2616: CoS setup → Loop 1 executes (or skips if max_paths==0)
3. Line 2628-2695: **Path allocation happens HERE** → max_paths set to 8

**Timeline Problem:**
- When loops execute at lines 2612 and 2247, `max_paths` is still 0
- Loops are skipped
- Paths get allocated later at line 2628-2695
- Too late - loops already executed

### Why It Works on Waco5

**Different behavior:** Paths already exist BEFORE Modify QP is called

Evidence from Waco5 log:
```
max_paths=8, path_qid_base=4096  (at line 2516 debug log)
```

This means:
- Paths were created during CREATE_QP or an earlier Modify QP operation
- When the Modify QP to RTR executes, max_paths is already 8
- Both loops execute successfully
- All 8 paths get updated

---

## Root Cause: Code Difference Between Versions

### Theory: Path Allocation Timing Changed

**1.125.0-a (SMC1):**
- Paths allocated during Modify QP to RTR
- Path allocation happens AFTER the update loops
- Loops skip, paths never get CoS/CC updates

**1.125.1-a (Waco5):**
- Paths allocated earlier (during CREATE_QP?)
- When Modify QP to RTR executes, paths already exist
- Loops execute, paths get updated

### The Missing Debug Logs on SMC1 New Test

The new SMC1 test is missing the critical debug traces:
- Line 2529: "Modify QP AH(...max_paths=X...)" - **Missing**
- Line 2548/2534: "Using default profile" - **Missing**
- Line 2555/2540: "Congestion control enabled/disabled" - **Missing**
- Line 2558/2543: "CC Profile ID" - **Missing**

**Why?** The Modify QP operation likely happened before the console logging started capturing, or there's a different code path being taken in the new test.

---

## Code Difference to Investigate

Need to compare between 1.125.0-a-112 and 1.125.1-a:

**Option 1: Path Allocation Moved to CREATE_QP**
- Check if CREATE_QP allocates paths in 1.125.1 but not in 1.125.0

**Option 2: Modify QP Sequencing Changed**
- Check if qp_set_tp_params() and path CoS update loops were moved AFTER path allocation

**Option 3: Conditional Logic Changed**
- Check if there's a version-specific #ifdef that changes when paths are allocated

### Git Diff Command

```bash
cd /ws/pradeept/ws/usr/src/github.com/pensando/sw
git diff 1.125.0-a-112..1.125.1-a -- nic/rudra/src/hydra/nicmgr/plugin/rdma/admincmd_handler.c
```

Focus on:
1. `eth_rdma_impl_qp_modify()` function
2. `eth_rdma_impl_aq_qp_create_hdlr()` function
3. Path allocation logic (`hydra_path_alloc`)
4. Any #ifdef VULCANO or version-specific conditionals

---

## Impact on SMC1

Since `eth_rdma_impl_aq_qp_update_path_cos()` is not called, paths are missing:

1. **CoS configuration** - cosA, cosB not set correctly
2. **CoS selector** - cos_sel for ACK/NAK rings not configured
3. **Autoclear** - `sched_auto_clear` not set on paths (only on QP)

This causes:
- QoS/traffic prioritization issues
- Scheduler behavior problems
- Potential ACK/NAK handling issues
- Performance degradation

---

## Next Steps

1. **Compare git diff** between 1.125.0-a-112 and 1.125.1-a for:
   - When paths are allocated (CREATE_QP vs MODIFY_QP)
   - Order of operations in eth_rdma_impl_qp_modify()
   - Any VULCANO-specific path allocation changes

2. **Test with detailed debug logs:**
   - Enable DEBUG level logging on SMC1
   - Capture full Modify QP sequence including line 2503/2529 debug traces

3. **Verify the fix:**
   - Apply code from 1.125.1-a to SMC1
   - Or manually add path update calls after line 2695

---

## Log Files

- **SMC1 Old (1-path test):** `/home/pradeept/vulcano-logs/smc1-ai0-console-old-20260302-164519.log`
- **SMC1 New (8-path test):** `/home/pradeept/vulcano-logs/smc1-ai0-console.log`
- **Waco5 (8-path working):** `/home/pradeept/vulcano-logs/waco5-ai0-console.log`

---
Last updated: 2026-03-02
