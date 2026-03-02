# Hydra Autoclear Behavior

## Overview

Hydra implements dynamic autoclear optimization that adapts based on workload scale to balance performance and resource efficiency.

**Source:** `nic/rudra/src/hydra/nicmgr/plugin/rdma/admincmd_handler.c:167-272`

## What is Autoclear?

**TXS (Transmit Scheduler) Autoclear** is a hardware optimization that automatically clears/invalidates completed work queue entries without software intervention.

**Purpose:**
- Reduces CPU overhead for work queue management
- Improves latency for low-scale workloads
- Can cause scheduling contention at high scale

## Scale-Based Behavior

Hydra uses **two modes**:

### Low-Scale Mode
**Triggers:**
- Active qstates < 64 **AND**
- No RCCL QPs present

**Configuration:**
```
✓ UPD protocol: ENABLED
✓ TXS auto clear: ENABLED
✓ Invalidate coalescing: DISABLED
```

**Optimized for:** Low latency, small number of QPs

---

### High-Scale Mode
**Triggers when EITHER:**
- Active qstates >= 64 (HIGH_SCALE_ACTIVE_QSTATES_THRESHOLD) **OR**
- Any RCCL QPs exist (RCCL QPs > 0)

**Configuration:**
```
✓ UPD protocol: DISABLED
✓ TXS auto clear: DISABLED  ← Key change
✓ Invalidate coalescing: ENABLED
```

**Optimized for:** High throughput, many concurrent QPs

---

## Why Disable Autoclear for RCCL?

**Problem Observed:**
```
Comment from code (lines 167-172):
"With RCCL CTS and data QP in different qos group, and with auto-clear
disabled, we are seeing degradation in performance. On CTS QPs, we see
its eating up into data QPs scheduling with auto clear disable."
```

**Solution:**
- **Global autoclear:** DISABLED for high-scale/RCCL
- **Per-QP autoclear:** Only enabled for non-RCCL data QPs
- **RCCL QPs:** Autoclear explicitly disabled (sched_auto_clear = 0)

**Implementation:**
```c
if ((is_rccl == false) && eth_lif_sched_cos_info(lif, cos)->auto_clear) {
    p_cb0->sched_auto_clear = 1;  // Enable only for non-RCCL QPs
}
```

## Transition Logic

The system transitions between modes dynamically:

### Scale-Up Transition
**Trigger:** Entering high-scale mode
```c
hydra_scale_up_config():
1. nicmgr_impl_rccl_update(true);              // Disable UPD protocol
2. nicmgr_impl_global_auto_clear_set(false);   // Disable TXS autoclear
3. PAL_barrier();                               // Memory barrier
4. update_table_constant_auto_clear_en(false); // Clear table constant
```

**Ordering is critical:**
- Disable global autoclear at TXS first
- Then clear table constant
- Ensures revals are skipped only after autoclear is safely disabled

### Scale-Down Transition
**Trigger:** Returning to low-scale mode
```c
hydra_scale_down_config():
1. nicmgr_impl_rccl_update(false);            // Enable UPD protocol
2. update_table_constant_auto_clear_en(true); // Set table constant first
3. PAL_barrier();                              // Memory barrier
4. nicmgr_impl_global_auto_clear_set(true);   // Enable TXS autoclear
```

**Ordering is critical:**
- Set table constant first
- Then enable TXS autoclear
- Ensures we don't skip revals before TXS goes into autoclear mode

## Scenarios

### Scenario 1: First RCCL QP Created
**State:** Low-scale (qstates < 64, RCCL QPs = 0)
**Event:** RCCL QP created (0 → 1)
**Action:** Scale up (disable autoclear)

### Scenario 2: QP Count Crosses Threshold
**State:** Low-scale (qstates < 64, RCCL QPs = 0)
**Event:** Qstates crosses threshold (< 64 → >= 64)
**Action:** Scale up (disable autoclear)

### Scenario 3: Qstates Drops Below Threshold
**State:** High-scale (qstates >= 64, RCCL QPs = 0)
**Event:** Qstates drops (>= 64 → < 64)
**Action:** Scale down (enable autoclear)

### Scenario 4: Last RCCL QP Destroyed
**State:** High-scale (qstates < 64, RCCL QPs >= 1)
**Event:** Last RCCL QP destroyed (>= 1 → 0)
**Action:** Scale down (enable autoclear)

### Scenario 5: Both Conditions Present
**State:** High-scale (qstates < 64, RCCL QPs >= 1)
**Event:** Qstates crosses up (< 64 → >= 64)
**Action:** No change (already high-scale)

### Scenario 6: RCCL Ends But Qstates Still High
**State:** High-scale (qstates >= 64, RCCL QPs >= 1)
**Event:** Last RCCL QP destroyed
**Action:** No change (still high-scale due to qstates)

## Per-QP Autoclear Settings

### Non-RCCL QPs
```c
if (!is_rccl) {
    if (eth_lif_sched_cos_info(lif, cos)->auto_clear) {
        p_sqcb0->sched_auto_clear = 1;  // Enable per-QP autoclear
        p_rqcb0->sched_auto_clear = 1;
    }
}
```

**Behavior:** Autoclear controlled by CoS (Class of Service) configuration

### RCCL QPs
```c
if (is_rccl) {
    // Auto-clear explicitly NOT set for RCCL QPs
    // Relies on global autoclear being disabled
}
```

**Behavior:** Always has autoclear disabled, regardless of global setting

## CoS-Specific Autoclear

**For RCCL with different CoS for CTS and Data:**
- Global autoclear: Disabled
- Data CoS qgroups: Autoclear disabled
- CTS (control) QPs: May have different setting

**Goal:** Prevent CTS QPs from interfering with data QP scheduling

## Implementation Details

### Functions

**`hydra_scale_up_config()`** (admincmd_handler.c:212-226)
- Disables autoclear for high-scale scenarios
- Sets global and table constant flags

**`hydra_scale_down_config()`** (admincmd_handler.c:228-243)
- Enables autoclear for low-scale scenarios
- Reverse operation of scale-up

**`hydra_should_use_high_scale_config()`** (admincmd_handler.c:245-255)
- Determines if system should be in high-scale mode
- Checks qstate count and RCCL QP presence

**`hydra_apply_scale_config_if_needed()`** (admincmd_handler.c:257-272)
- Applies configuration changes only during transitions
- Maintains state to avoid redundant updates

### Global Variables

- `HIGH_SCALE_ACTIVE_QSTATES_THRESHOLD` = 64
  - Threshold for switching modes based on active qstates

- `g_rccl_data_cos`
  - CoS value used for RCCL data traffic

- `g_num_qps`
  - Total number of QPs

## Memory Barriers

**Critical for correctness:**
```c
PAL_barrier();  // Ensures ordering between steps
```

Prevents reordering of:
1. Global autoclear disable
2. Table constant update

Ensures atomic transition between modes.

## Platform Differences

### Vulcano
```c
#if defined(VULCANO)
    cos = 3;      // Data QP CoS
    ack_cos = 2;  // ACK QP CoS
#endif
```

Different CoS assignments for Vulcano vs Salina.

## Performance Impact

### With Autoclear Enabled (Low-Scale)
**Pros:**
- Lower latency for small transfers
- Less software intervention
- Better for latency-sensitive workloads

**Cons:**
- Can cause scheduling conflicts at high scale
- CTS QPs interfere with data QPs

### With Autoclear Disabled (High-Scale/RCCL)
**Pros:**
- Better scheduling fairness between QP types
- Prevents CTS interference with data QPs
- Better for high-throughput workloads

**Cons:**
- Slightly higher latency for small operations
- More software overhead

## Debug/Monitoring

### Check Current Mode

Via console or logs, look for:
```
NICMGR_TRACE_INFO("Enabling high-scale optimizations - active qstates: %u", ...)
NICMGR_TRACE_INFO("Disabling high-scale optimizations - active qstates: %u", ...)
```

### Via Vulcano Console
```bash
# Connect to Vulcano console
telnet <host> <port>

# Check current configuration
show device
show status

# May need specific debug commands to see autoclear state
```

## Related Code

- `nicmgr_impl_global_auto_clear_set()` - Sets global TXS autoclear
- `update_table_constant_auto_clear_en()` - Updates table constant for autoclear
- `nicmgr_impl_rccl_update()` - Updates RCCL-specific optimizations
- `eth_lif_sched_cos_info()` - Gets CoS scheduling information

## Summary

Hydra's autoclear is **adaptive**:
- **Low-scale:** Autoclear ON (optimize latency)
- **High-scale/RCCL:** Autoclear OFF (optimize throughput, prevent scheduling conflicts)
- **Transitions:** Carefully ordered with memory barriers
- **Per-QP:** RCCL QPs never use autoclear, non-RCCL can use it
- **CoS-aware:** Different behavior for data vs control traffic

This optimization allows Hydra to perform well across different workload characteristics without manual tuning.

---
**File:** `nic/rudra/src/hydra/nicmgr/plugin/rdma/admincmd_handler.c`
**Key Lines:** 167-272 (scale config), 503-505, 574-576, 789-792, 859-862 (per-QP settings)
**Threshold:** 64 active qstates
**Last Updated:** 2026-02-25
