# Hydra Autoclear Behavior

> **STATUS (verified 2026-07-13): the dynamic scale-based autoclear-disable is
> now SALINA-ONLY.** The whole scale-config machinery is wrapped in
> `#if defined(SALINA)` (`admincmd_handler.c:291-376`, plus all threshold-crossing
> and RCCL-trigger call sites). **On Vulcano, autoclear is enabled at init and
> stays ON for all QPs at all scales, including RCCL** — see the explicit comment
> at `admincmd_handler.c:991`. The "two modes / all platforms" description below
> was accurate as of 2026-02-25 but now applies to **Salina only**. Read the
> per-section notes for the current Vulcano behavior.

## Overview

Hydra implements dynamic autoclear optimization that adapts based on workload
scale. **This dynamic adaptation is Salina-only today; Vulcano keeps autoclear
always on** (see status banner above).

**Source:** `nic/rudra/src/hydra/nicmgr/plugin/rdma/admincmd_handler.c` — scale
config block `:291-376` (Salina-gated), per-QP autoclear `:1056-1058` (SQ),
`:1134-1136` (RQ), Vulcano init-only comment `:991`.

## What is Autoclear?

**TXS (Transmit Scheduler) Autoclear** is a hardware optimization that automatically clears/invalidates completed work queue entries without software intervention.

**Purpose:**
- Reduces CPU overhead for work queue management
- Improves latency for low-scale workloads
- Can cause scheduling contention at high scale

## Scale-Based Behavior

> **Applies to SALINA only.** On Vulcano there are no modes — autoclear is
> always on.

Salina uses **two modes**:

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

## Why Disable Autoclear for RCCL? (SALINA only)

> **This RCCL-specific handling is Salina-only today.** On Vulcano, RCCL QPs get
> autoclear on the same terms as any other QP (CoS-driven), and the per-QP
> `is_rccl` exclusion has been **removed** — see "Per-QP Autoclear Settings"
> below for the current code.

**Problem Observed (Salina):**
```
Comment from code:
"With RCCL CTS and data QP in different qos group, and with auto-clear
disabled, we are seeing degradation in performance. On CTS QPs, we see
its eating up into data QPs scheduling with auto clear disable."
```

**Salina solution:**
- **Global autoclear:** DISABLED for high-scale/RCCL
- **Per-QP autoclear:** driven by CoS config (see current code below)

**Historical implementation (pre-refactor — no longer in tree):**
```c
// OLD: per-QP autoclear was gated on is_rccl
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

> **Current code (verified 2026-07-13): the `is_rccl` gate is gone on both
> platforms.** Per-QP autoclear is now driven purely by the CoS `auto_clear`
> config. RCCL QPs are treated like any other QP at the per-QP level.

**Current implementation** (`admincmd_handler.c` — SQ `:1056-1058`, RQ
`:1134-1136`; QP-modify `:3134-3139`):
```c
// SQ CB — set if EITHER cosA or cosB has auto_clear (no is_rccl check)
if (eth_lif_sched_cos_info(lif, cosA)->auto_clear ||
    eth_lif_sched_cos_info(lif, cosB)->auto_clear) {
    p_sqcb0->sched_auto_clear = 1;
}
// RQ CB — same pattern
// QP modify — set/clear both SQ and RQ based on cos auto_clear
```

**Behavior:**
- **Vulcano:** per-QP autoclear reflects CoS config and stays on (no global
  scale-disable overrides it).
- **Salina:** per-QP CoS config still interacts with the global scale-based
  disable (`configure_global_autoclear`), so effective autoclear can be turned
  off globally at high scale even if the CoS enables it per-QP.

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

**Current (2026-07-13):**
- **Vulcano:** autoclear **always ON** (enabled at init, never scale-disabled).
  Per-QP autoclear is CoS-driven; no `is_rccl` gate; no global scale-disable.
- **Salina:** autoclear is **adaptive** (the behavior this doc originally
  described):
  - Low-scale: ON (optimize latency)
  - High-scale/RCCL (≥64 qstates or any RCCL QP): OFF (throughput, avoid
    CTS-vs-data scheduling conflicts)
  - Transitions carefully ordered with memory barriers (`configure_global_autoclear`)

**On Vulcano always-on auto-clear:** empirically **verified NOT to be a problem**
(2026-07-13) — no fairness/perf pain at scale or RCCL. So Vulcano intentionally
keeps auto-clear on and has no need for the pulsar-style `txs_cmd` fast-path.
The `HYDRA-TXS-DESIGN.md` port is therefore **parked** (kept as reference only,
for the hypothetical case where Vulcano ever needs auto-clear off).

---
**File:** `nic/rudra/src/hydra/nicmgr/plugin/rdma/admincmd_handler.c`
**Key Lines (current):** `291-376` scale config (Salina-gated), `980-991`
RCCL trigger + Vulcano no-op comment, `1056-1058`/`1134-1136` per-QP SQ/RQ
autoclear, `3134-3139` QP-modify
**Threshold:** 64 active qstates (Salina only)
**Last Updated:** 2026-07-13 (was 2026-02-25; corrected to reflect Salina-only
scale-disable + Vulcano always-on)
