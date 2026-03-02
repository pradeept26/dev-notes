# Vulcano Autoclear Changes - Analysis

## Requirement
Disable dynamic autoclear optimization and RCCL-specific autoclear disabling **for Vulcano only**.
Keep current behavior for Salina.

## Current Behavior

### For ALL Platforms (Vulcano + Salina)
**Dynamic scaling triggers autoclear disable when:**
1. Active qstates >= 64, OR
2. Any RCCL QP is created

**Result:** Autoclear is disabled globally for high-scale or RCCL workloads

## Desired Behavior

### For Vulcano
**Always keep autoclear ENABLED:**
- Ignore qstate count threshold
- Ignore RCCL QP presence
- Never call `hydra_scale_up_config()` or `hydra_scale_down_config()`
- Always keep `sched_auto_clear = 1` for all QPs (including RCCL)

### For Salina
**Keep current dynamic behavior:**
- Scale up/down based on qstate count
- Disable autoclear for RCCL QPs
- Keep existing logic unchanged

---

## Code Changes Required

### Change 1: Wrap Scale Functions with Platform Check

**Location:** Lines 212-243 (hydra_scale_up_config, hydra_scale_down_config)

**Current:**
```c
static void
hydra_scale_up_config(void)
{
    nicmgr_impl_rccl_update(true);
    nicmgr_impl_global_auto_clear_set(false);  // ← Disables autoclear
    PAL_barrier();
    update_table_constant_auto_clear_en(false);
}

static void
hydra_scale_down_config(void)
{
    nicmgr_impl_rccl_update(false);
    update_table_constant_auto_clear_en(true);
    PAL_barrier();
    nicmgr_impl_global_auto_clear_set(true);  // ← Enables autoclear
}
```

**Proposed Change:**
```c
static void
hydra_scale_up_config(void)
{
#if defined(SALINA)
    // Only apply dynamic scaling for Salina
    uint32_t total_active_qstates = get_total_active_qstates();
    NICMGR_TRACE_INFO("Enabling high-scale optimizations - active qstates: %u",
                      total_active_qstates);
    nicmgr_impl_rccl_update(true);
    nicmgr_impl_global_auto_clear_set(false);
    PAL_barrier();
    update_table_constant_auto_clear_en(false);
#elif defined(VULCANO)
    // For Vulcano: Keep autoclear always enabled
    NICMGR_TRACE_INFO("Vulcano: Skipping scale-up, keeping autoclear enabled");
    // No action - autoclear stays enabled
#endif
}

static void
hydra_scale_down_config(void)
{
#if defined(SALINA)
    // Only apply dynamic scaling for Salina
    uint32_t total_active_qstates = get_total_active_qstates();
    NICMGR_TRACE_INFO("Disabling high-scale optimizations - active qstates: %u",
                      total_active_qstates);
    nicmgr_impl_rccl_update(false);
    update_table_constant_auto_clear_en(true);
    PAL_barrier();
    nicmgr_impl_global_auto_clear_set(true);
#elif defined(VULCANO)
    // For Vulcano: Keep autoclear always enabled
    NICMGR_TRACE_INFO("Vulcano: Skipping scale-down, keeping autoclear enabled");
    // No action - autoclear stays enabled
#endif
}
```

---

### Change 2: Make Scale Detection Salina-Only

**Location:** Line 247 (hydra_should_use_high_scale_config)

**Current:**
```c
static bool
hydra_should_use_high_scale_config(void)
{
    uint32_t total_active_qstates = get_total_active_qstates();
    uint32_t total_rccl_qps = get_total_rccl_qps();
    return (total_active_qstates >= HIGH_SCALE_ACTIVE_QSTATES_THRESHOLD) || (total_rccl_qps > 0);
}
```

**Proposed Change:**
```c
static bool
hydra_should_use_high_scale_config(void)
{
#if defined(SALINA)
    // Salina: Use dynamic scaling based on qstates and RCCL
    uint32_t total_active_qstates = get_total_active_qstates();
    uint32_t total_rccl_qps = get_total_rccl_qps();
    return (total_active_qstates >= HIGH_SCALE_ACTIVE_QSTATES_THRESHOLD) || (total_rccl_qps > 0);
#elif defined(VULCANO)
    // Vulcano: Always stay in low-scale mode (autoclear enabled)
    return false;
#else
    return false;
#endif
}
```

---

### Change 3: Enable Autoclear for RCCL QPs on Vulcano

**Location:** Lines 503-505, 574-576, 789-792, 859-862

**Current (multiple locations):**
```c
if ((is_rccl == false) && eth_lif_sched_cos_info(lif, cos)->auto_clear) {
    p_cb0->sched_auto_clear = 1;
}
```

**Proposed Change:**
```c
#if defined(VULCANO)
// Vulcano: Enable autoclear for all QPs including RCCL
if (eth_lif_sched_cos_info(lif, cos)->auto_clear) {
    p_cb0->sched_auto_clear = 1;
}
#elif defined(SALINA)
// Salina: Disable autoclear for RCCL QPs (current behavior)
if ((is_rccl == false) && eth_lif_sched_cos_info(lif, cos)->auto_clear) {
    p_cb0->sched_auto_clear = 1;
}
#endif
```

**Apply to ALL four locations:**
1. Line 503-505 (path CB)
2. Line 574-576 (path CB duplicate)
3. Line 789-792 (SQ CB)
4. Line 859-862 (RQ CB)

---

### Change 4: Remove RCCL QP Tracking Calls (Salina-only)

**Location:** Lines 736-743 (QP create), 2925-2932 (QP destroy)

**Current:**
```c
// Apply scaling config only when creating the first RCCL QP (0 -> 1 transition)
uint32_t total_rccl_qps = get_total_rccl_qps();
if (total_rccl_qps == 1) {
    NICMGR_TRACE_INFO("%s: RDMA AQ: first rccl qp %d (LIF %u)", ...);
    hydra_apply_scale_config_if_needed();
}
```

**Proposed Change:**
```c
#if defined(SALINA)
// Apply scaling config only when creating the first RCCL QP (0 -> 1 transition)
uint32_t total_rccl_qps = get_total_rccl_qps();
if (total_rccl_qps == 1) {
    NICMGR_TRACE_INFO("%s: RDMA AQ: first rccl qp %d (LIF %u)", ...);
    hydra_apply_scale_config_if_needed();
}
#elif defined(VULCANO)
// Vulcano: No scaling config changes for RCCL
NICMGR_TRACE_INFO("%s: RDMA AQ: rccl qp %d created (LIF %u), autoclear stays enabled", ...);
#endif
```

Similarly for QP destroy (lines 2925-2932).

---

### Change 5: Keep Threshold Crossing Salina-Only

**Already correct!** Lines 274-289, 628-641, 2827-2840, 2936-2951

These are already wrapped in `#if defined(SALINA)` blocks ✓

---

## Summary of Changes

### Files to Modify
- **Single file:** `nic/rudra/src/hydra/nicmgr/plugin/rdma/admincmd_handler.c`

### Changes Needed (5 locations)

| Change | Lines | Description |
|--------|-------|-------------|
| 1 | 212-243 | Wrap scale_up/scale_down with `#if defined(SALINA)` |
| 2 | 247-255 | Make should_use_high_scale return false for Vulcano |
| 3a | 503-505 | Enable autoclear for RCCL on Vulcano (path CB) |
| 3b | 574-576 | Enable autoclear for RCCL on Vulcano (path CB dup) |
| 3c | 789-792 | Enable autoclear for RCCL on Vulcano (SQ CB) |
| 3d | 859-862 | Enable autoclear for RCCL on Vulcano (RQ CB) |
| 4a | 736-743 | Wrap RCCL scale trigger with `#if defined(SALINA)` |
| 4b | 2925-2932 | Wrap RCCL scale trigger with `#if defined(SALINA)` |

### Already Platform-Specific (No Change Needed)
- Lines 274-289: `hydra_check_threshold_crossing()` - Already Salina-only ✓
- Lines 628-641: Path create threshold check - Already Salina-only ✓
- Lines 2827-2840: Path destroy threshold check - Already Salina-only ✓
- Lines 2936-2951: QP destroy threshold check - Already Salina-only ✓

---

## Expected Behavior After Changes

### Vulcano
```
✓ Autoclear: ALWAYS ENABLED (never disabled)
✓ No dynamic scaling based on qstate count
✓ No special handling for RCCL QPs
✓ All QPs (RCCL and non-RCCL) use autoclear
✓ Simpler, more predictable behavior
```

### Salina
```
✓ Autoclear: DYNAMIC (current behavior unchanged)
✓ Scales based on qstate threshold (64)
✓ Disables for RCCL QPs
✓ All current logic preserved
```

---

## Testing After Changes

### Verify Vulcano Behavior
1. Build firmware with changes
2. Load on Vulcano hardware
3. Create RCCL QPs
4. Check via logs/console that autoclear stays enabled
5. Run RCCL bandwidth test - should maintain performance

### Verify Salina Unchanged
1. Build same firmware
2. Load on Salina hardware
3. Verify dynamic scaling still works
4. Check threshold crossing behavior
5. Ensure no regressions

---

## Implementation Approach

### Option 1: Minimal Changes (Recommended)
Wrap only the essential functions:
- `hydra_scale_up_config()` - Make Salina-only
- `hydra_scale_down_config()` - Make Salina-only
- `hydra_should_use_high_scale_config()` - Return false for Vulcano
- Per-QP autoclear settings - Remove `is_rccl` check for Vulcano

**Pros:** Minimal code change, clear platform separation
**Cons:** Some dead code for Vulcano (scale functions exist but never called)

### Option 2: Complete Separation
Create separate codepaths:
- `#if defined(VULCANO)` - Simple, always-on autoclear
- `#if defined(SALINA)` - Complex, dynamic scaling

**Pros:** Cleaner separation, no dead code
**Cons:** More code duplication, larger diff

**Recommendation:** Use Option 1 (minimal changes)

---

## Risk Assessment

**Low Risk:**
- Changes are platform-guarded (`#if defined(...)`)
- Vulcano and Salina are separate build targets
- No shared code affected
- Easy to revert if issues found

**Testing Required:**
- Vulcano: RCCL performance with autoclear always on
- Salina: Ensure no regression in current behavior
- Both: Functional testing (DOL, GTest)

---

## Code Review Checklist

- [ ] All scale_up/scale_down calls wrapped with Salina check
- [ ] Vulcano returns false from should_use_high_scale
- [ ] All 4 per-QP autoclear locations updated for Vulcano
- [ ] RCCL tracking calls wrapped with Salina check
- [ ] Trace messages updated for clarity
- [ ] No compilation warnings
- [ ] Tested on both Vulcano and Salina hardware

---

**Created:** 2026-02-25
**File to Modify:** nic/rudra/src/hydra/nicmgr/plugin/rdma/admincmd_handler.c
**Changes:** 8 code blocks across 5 logical changes
**Risk:** Low (platform-guarded)
**Testing:** Required on both Vulcano and Salina
