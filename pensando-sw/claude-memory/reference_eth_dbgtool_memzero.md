---
name: eth_dbgtool memzero — host-side HBM read/zero
description: Host tool to directly zero/access NIC HBM addresses without a firmware reflash (e.g. reset debug counters in atomic stat regions)
type: reference
originSessionId: 1418ad7a-e393-49d8-aa61-76d2bde9f02b
---
`eth_dbgtool memzero <hbm_addr> <len_bytes>` zeroes HBM directly **from the x86 host**
(no firmware reflash, no card reset). Useful for resetting debug counters that live in
HBM regions the normal CLIs don't clear.

**Why it matters:** ASIC HBM addresses (0x1_0000_0000 range) are normally only
read/written on the NIC side via `pal_mem_rd/wr`; they're NOT `devmem`-able from the host.
`eth_dbgtool` gives host-side direct HBM access (SDK-mapped), so you can poke/zero regions
for debugging.

**How to get a region's absolute HBM address:** resolved per-build in
`nic/rudra/build/.../vulcano/gen/mem.json` (each region has a `"start"` field). These are
build-specific — they shift if region sizes change on another branch. Firmware should use
`nicmgr_impl_mem_region_info_get("<region>", &base, ...)`, not a hardcoded constant.

**Example (RL debug-stats work):** `cc_atomic_stats` region — offsets 0/8 = CC active-queue
gauge (incr/decr, net = live queues), offset 16 = `rl_spec_fail_count` (my debug counter).
- Reset only the spec-fail counter (surgical, leaves CC gauge intact):
  `eth_dbgtool memzero <cc_atomic_stats_base + 16> 8`
- Zeroing the whole first 32B also clears CC's active-queue gauge — harmless only when
  traffic is stopped / RL disabled; mid-run it makes the active-queue net read negative.
