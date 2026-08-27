---
name: AI-7677 GT alltoall regression — resolved
description: Root cause, fix, validation results for GT Vulcano 4x100G alltoall 22% regression
type: project
originSessionId: 2431faa0-7c48-4a10-a709-cb3f6bf2249b
---
**Status: RESOLVED in 1.130.5-a-13**

**Root cause:** Murali (PR #118792) + Shantanu (rtos commit 61ccea13) changed MAC/PHY lane assignment for 4x100G_1 profile from alternate lanes (1,3,5,7) to consecutive (1,2,3,4). On OSFP-800G-CR8 copper, consecutive lanes cause adjacent-lane crosstalk → bimodal RTT (47% >75µs) → path disabling → 22% alltoall regression.

**Fix (Nataraj, 4 commits in 1.130.5-a-13):**
- `bd5d5e3` — Fix TM oport formula S5: `port_index << PORT_OPORT_SHIFT_BITS`
- `3d1fd4f` — Remove nonzero_path_port_bitmap, fix cur_path_group_offset
- `2b57c28` — Fix ACK port_index derivation S2: `ack_tm_port >> PORT_OPORT_SHIFT_BITS`
- `eb06102` — Fix RCN rate hints: 4×100G=400Gbps not 800Gbps

**Validation (ROCm 7.0.2, all 10 collectives × 5 iters):** All within ±2% of 2-a-11 baseline.
alltoall: 82.4 vs 82.5 GB/s (-0.1%), all_reduce: 351.5 vs 350.9 (+0.2%)

**Why:** 5-a-7 had bimodal RTT (47% >75µs), 84% QPs with 6-8 paths disabled, add:mul ratio 152:1.
5-a-13 has clean 91% RTT in 25-50µs range, zero disabled paths, balanced CC.

**How to apply:** The fix is in the TM oport calculation — nicmgr computes `PORT_OPORT_SHIFT_BITS = log2(agg_rate/(num_uplinks×100))` at init and programs it as table constant. For 4×100G: shift=0 → ports map 1:1. For 2×400G: shift=2.
