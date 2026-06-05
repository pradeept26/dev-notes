---
name: PIC RL port to 1.130-a — development handoff (2026-06-05)
description: Full development story for porting Vishwas's PIC rate-limiter from 1.125-a-spray to 1.130-a — IPC enum conflict, Zephyr RAM overflow fix, firmware-side TXS/PICS wiring discovery, SMC bring-up debugging, kenya verification, and known bugs
type: project
---

# Handoff — PIC RL Port to 1.130-a (Vulcano, Hydra Meta RoCE)

> **Purpose:** Complete development record for the PIC rate-limiter port. Covers everything from the source port through SMC/kenya verification. A new session should be able to pick up this work, understand every design decision, and know what's still broken.

---

## 0. TL;DR

- **What:** Per-LIF-group HW rate limiter for Hydra Meta RoCE on Vulcano, ported from Vishwas's 1.125-a-spray work to **1.130-a** with a new firmware helper that eliminates manual register pokes.
- **Where (code):**
  - Branch: `pic-rl-1.130-a` on `github.com/pradeept26/sw` (commit `680df4b402b`)
  - Submodule patch: `~/share/pic-rl-2026-06-05/ainic-rtos.patch` (Ben's unmerged PR #1350)
- **Built artifacts (matching):**
  - `/ws/pradeept/ws/usr/src/github.com/pensando/sw-2/ainic_fw_vulcano.tar` (10.5 MB)
  - `nic/build/x86_64/hw/rudra/vulcano/out/nicctl_bin/nicctl.bin` (44 MB)
  - FW string: `1.130.0-a-5-36-g2f7d2cec259-dirty`
- **Verified on:** SMC (400 G, 8 NICs) and kenya-perf-3/4 (800 G, 1 NIC each). Harmless at line rate; correctly throttles when rate < link.
- **Known bug:** Disable path leaves dcache filter[7] valid=0 → ~7% throughput sag on subsequent tests. Card reset clears it. **Not yet fixed.**
- **Kenya verification handoff:** `~/dev-notes/pensando-sw/claude-memory/handoff_kenya_perf3_4_sweep_2026_06_05.md` §11.

---

## 1. What PIC RL is

**PIC (PICS)** is Vulcano's policer subsystem. Hardware token bucket per LIF group. Lives in P4 stage 4 (`pic_rl_tbl`) and the PICS scheduler block. Keyed by `p4_intr_global.lif`, which after the S0 conversion becomes the LIF **group** id (low 4 bits of the host LIF on Vulcano — 16 groups total; Salina has 9 bits).

**Why it exists:** transmit-side rate enforcement without firmware involvement on the datapath. Enables per-tenant BW limits, traffic shaping, harmless ceiling for SLA compliance.

**P4 table layout:**
- 16 entries, num_buckets=2
- Even group_ids in block 0 (y=512..519)
- Odd group_ids in block 1 (y=4608..4615)
- Each entry: `entry_valid`, `rlimit_en`, `pkt_rate`, `rate` (40-bit), `burst` (40-bit), `tbkt` (40-bit current token count)

**Rate formula (empirical):** `hw_rate = rate_bps / 24000`. This is what works in practice but may be off by ~1.33× from the formal ASIC formula (`raw_rate = refresh_cycle × 0.9 × bytes_per_clock`). Burst is the dominant BW-shaping factor — see §6.

---

## 2. The port story

### 2.1 Source

Vishwas's handoff: `/home/vishwas/project_pic_rl.md` (1.125-a-spray branch). Contains the P4 table programming, the basic helper functions, and a manual-poke recipe for the TXS/PICS wiring + dcache filter.

### 2.2 IPC enum conflict (38/39 → 40/41)

On 1.125-a-spray, IPC opcodes 38/39 were free, so Vishwas used them for `PIC_RL_UPDATE` / `PIC_RL_GET`. On 1.130-a, those slots are already taken by `RDMA_DROP` (test infrastructure for drop injection).

**Fix:** Rewrote `nic/sdk/rtos-shared/include/ipc/internal.h` to put PIC_RL at **40/41**. Touched:
- `IPC_MSG_OPCODE_PIC_RL_UPDATE = 40`
- `IPC_MSG_OPCODE_PIC_RL_GET = 41`
- `zipc_pic_rl_upd_msg_t` / `zipc_pic_rl_get_msg_t` struct definitions

Also added `uint16_t lif_id` to `pic_rl_params_t` (was missing on Vishwas's version — see §3).

### 2.3 SoC Zephyr RAM overflow

After adding the new `vulcano_pic_rl_lif_program()` helper (§4), the SoC Zephyr image overflowed by **17,296 bytes**. Zephyr build hard-fails on overflow.

**Fix:** Applied Ben Jameson's unmerged ainic-rtos PR #1350 — removes the RAS CPER pretty-print path (~23 KB SoC RAM savings). Net delta after fix: ~6 KB headroom.

This is staged as a submodule patch (`~/share/pic-rl-2026-06-05/ainic-rtos.patch`) because PR #1350 isn't merged upstream yet. Every consumer of the PIC RL branch needs to apply it until #1350 lands.

---

## 3. The LIF group derivation problem (initial SMC failure)

### Symptom

Enabled PIC RL on SMC at 100 Gbps → traffic was NOT throttled. Saw line-rate BW regardless of rate setting.

### Root cause

Vishwas's original code had `PIC_RL_LIF_GROUP_ID=1` **hardcoded**. SMC's RDMA SQ LIF lands at host hw_id=2, so `sub_lif = 2 | (1<<4) = 18`, which gives `group_id = 18 & 0xF = 2`. The policer was programmed for group 1, but traffic went through group 2 — silent miss.

### How we found it

Used `/debug-meta-roce` skill to dump pathcb raw output:
```
nicctl show pipeline internal rdma queues --type pathcb0 --queue-id 0 --raw
```
Found `rdma_lif = 0x12` (= 18) in the pathcb header → confirmed SQ sub_lif=18 → group=2.

### Fix

1. Added `--lif <host_lif>` flag to `nicctl debug update/show pipeline internal rate-limit` so the user supplies the host LIF id (from `nicctl show lif --json` hw_id).
2. Derive group at runtime in firmware: `LIF_GROUP_ID(lif) = lif & 0xF` (Vulcano) or `lif & 0x1FF` (Salina).
3. Pass `lif_id` through IPC (`zipc_pic_rl_upd_msg_t.req.params.lif_id` and `zipc_pic_rl_get_msg_t.req.lif_id`).

**Caller responsibility:** user runs `nicctl show lif --json`, finds the host LIF's `hw_id`, computes `sub_lif = hw_id | (1<<4)`, passes that as `--lif`. Same number gives the group.

---

## 4. The firmware-side wiring helper

### Why it exists

P4 stage-4 policer alone is not enough. PICS correctly deducts tokens when a packet matches the rate-limited LIF group, but **TXS never sees the backpressure signal** for non-default LIF groups. Result: tokens drain to zero, packets keep flying, no throttle.

The PICS→TXS bridge needs explicit programming. On 1.125-a-spray, Vishwas did this with manual register pokes from userspace. We coded it into firmware so it happens automatically on `--enable`.

### What `vulcano_pic_rl_lif_program(lif_id, enable)` does

Lives in `nic/sdk/rtos-shared/src/lib/asicpd/vulcano/scheduler_vulcano.c`. Three actions:

**(1) TXS rlid_map programming**
- Looks up `q_grp_start` / `q_grp_end` from `lif_cfg_sram_entry[lif_id]`
- Programs two `rlid_map` entries:
  - `rlid_map[group_id]` → bucket 0 (UD0)
  - `rlid_map[2048+group_id]` → bucket 1 (UD1)
- Each entry sets `q_grp_start`/`end` to the LIF's qgrp range, valid=1 (or valid=0 on disable)

**(2) PICS scheduler_rl wiring**
- Sets `su1_pics_cfg_scheduler_rl[4].address_offset = 2048`
- This is the bridge: when PICS's token bucket goes negative at index `2048 + group_id`, it generates a backpressure RLID = `address_offset + entry_index = 2048 + group_id`, which is exactly what TXS's `rlid_map[2048+group_id]` is keyed on.
- **Slot 4 in scheduler_rl is empirical** — taken from Vishwas's working setup. We didn't reverse-engineer why slot 4 specifically; just preserved it.

**(3) dcache filter[7] disable**
- Disables dcache filter[7] valid bit on spg0/spg1 stage 4
- **Only done on enable**, NOT on disable (this is the BUG — see §7)
- Stage-level cache exclusion needed so PICS sees live SRAM updates instead of cached stale values

### Reverse-engineering process

Wasn't documented anywhere. Had to:
1. Stare at the asicpd headers (`scheduler_vulcano.h`, `lif_cfg_sram_entry` struct)
2. Read every register def under `su1_pics_cfg_scheduler_rl` (PICS block)
3. Try `address_offset` values until backpressure showed up at TXS counters
4. Empirically confirm slot=4, offset=2048, RLID encoding via traffic tests

**If anyone needs to debug this in future:** the PICS→TXS bridge is the non-obvious part. P4 policer + LIF cfg + rlid_map alone won't work. The `address_offset` + `slot 4` are the magic.

---

## 5. nicctl interface

### Update command
```bash
nicctl debug update pipeline internal rate-limit \
    --enable | --disable \
    --lif <host_lif_id>      # from `nicctl show lif --json` hw_id
    --rate-bps <bps>         # e.g., 100000000000 for 100G
    --burst-bytes <bytes>    # e.g., 16777216 for 16 MB
    --bdf <bdf>              # for multi-NIC hosts
```

### Show command
```bash
nicctl show pipeline internal rate-limit --lif <host_lif_id> --bdf <bdf>
```

Output:
```
NIC : <uuid> (<bdf>):
  LIF id:       18 (group 2)
  Enabled:      yes
  Rate (bps):   799999992000
  Burst (bytes):16777216
```

### Implementation files
- `nic/infra/ainic/nicctl/pipeline/hydra/internal.hpp` (struct + cb + flag wiring)
- `nic/infra/ainic/nicctl/pipeline/hydra/pipeline.cc` (cmd registration)

---

## 6. Burst-size is the BW limiter, not rate

### Discovery

Tried 100 G / 200 G / 400 G rates with 4 MB burst on SMC. Throughput **capped at ~573 Gbps regardless of rate**. Looked like the policer was clamping aggressively even when rate was set way above link.

### Root cause

Burst defines the maximum momentary token reservoir. With small burst:
- Bucket drains in <100 ns at 800 Gbps
- Refill happens at the configured rate, not at link rate
- Even though average rate is "800 G", instantaneous link is gated by token replenishment cadence
- Effective ceiling ≈ `burst / refresh_cycle`, not the nominal rate

### Working values

- **4 MB burst**: 573 Gbps cap (regardless of rate)
- **16 MB burst**: full line rate (1.5 Tbps bidir on 800 G NICs)
- Use **≥16 MB burst** as a rule for line-rate testing.

### User feedback

> "we need to experiment and reach line rate with RL.. do quick 10s runs or -n 10000 runs and figure out what works"

That experiment is how we landed on the 16 MB burst recommendation.

---

## 7. KNOWN BUG: dcache disable doesn't restore filter[7]

### Behavior

When user runs `--disable`, `vulcano_pic_rl_lif_program(lif_id, enable=false)` correctly clears `rlid_map` entries but **does NOT restore `dcache filter[7] valid=1`**. The filter stays at valid=0.

### Symptom

Subsequent tests on the same card show ~7% throughput regression vs. fresh card state. Initially looked like a test-to-test variance issue or "PIC RL hurts throughput", but it's stale filter state.

### Reproducer

1. Enable PIC RL on a card
2. Disable PIC RL
3. Run ib_write_bw → ~7% lower than fresh-card baseline
4. Reset card → next run matches fresh baseline

### Workaround

Card reset (`nicctl reset card --all`) between enable/disable cycles. Or manually restore `dcache filter[7] valid=1` via capview poke (script TBD).

### Fix (NOT yet implemented)

In `vulcano_pic_rl_lif_program()`, the disable path needs to:
```c
// On disable, restore dcache filter[7] valid=1
if (!enable) {
    asicpd_spg_dcache_filter_valid_set(spg0, 7, 1);
    asicpd_spg_dcache_filter_valid_set(spg1, 7, 1);
}
```
(pseudo-code — actual API may differ; check existing scheduler_vulcano.c for the spg dcache write helpers)

**Priority:** medium. Workaround (card reset) works fine for testing. Would be a real problem for production if RL is toggled often without resets.

---

## 8. Verification

### SMC (400 G, 8 NICs/node)

- Per-LIF policer correctly throttles only the scoped LIF group; other groups unaffected.
- Verified `rdma_lif=0x12` → group 2 derivation correct.
- Confirmed throttle math: 100G config produced ~100 Gbps measured, 400G produced near line rate.
- Hit the 16 MB burst threshold for line rate.

(Detailed SMC numbers were in prior conversation; not preserved here. The functional pass is what matters for the port.)

### Kenya (800 G, 1 NIC/node), 2K + 4K QP

Full results in `handoff_kenya_perf3_4_sweep_2026_06_05.md` §11. Headline:

| QP | Handoff baseline (RL-off) | Patched + RL-on @ 800G/16MB | Δ |
|---:|---:|---:|---:|
| 2048 | 1492.97 G | 1491.93 G | −0.07% |
| 4092 | 1433.98 G | 1437.24 G | +0.23% |

PCIe latency during 4K active phase: >99.84% in 0–2.5 µs bucket on both ends. No degradation.

**Conclusion:** PIC RL is harmless at line rate on both 400 G and 800 G profiles. Does NOT recover the hcache-pressure dip at 4K QP (that's a separate HW characteristic).

---

## 9. Code change summary

All on branch `pic-rl-1.130-a` (`github.com/pradeept26/sw`), commit `680df4b402b`. 16 files, +824 −1.

### New files
- `nic/rudra/src/hydra/nicmgr/plugin/rdma/rdma_pic_rl.c` — IPC handlers, P4 pic_rl_tbl programmer, calls firmware helper
- `nic/rudra/src/hydra/nicmgr/plugin/rdma/rdma_pic_rl.h` — header

### Modified (key files)
- `nic/sdk/rtos-shared/include/ipc/internal.h` — IPC opcodes 40/41, msg structs, `lif_id` in params
- `nic/sdk/rtos-shared/src/lib/asicpd/vulcano/scheduler_vulcano.c` — `vulcano_pic_rl_lif_program()` helper (the main firmware contribution)
- `nic/sdk/rtos-shared/src/lib/asicpd/vulcano/include/asicpd_vulcano/scheduler_vulcano.h` — declares helper
- `nic/infra/ainic/nicctl/pipeline/hydra/internal.hpp` — `--lif` flag, cmd struct
- `nic/infra/ainic/nicctl/pipeline/hydra/pipeline.cc` — cmd registration
- `nic/rudra/src/hydra/p4/p4plus-16/meta_roce/tx/meta_roce_tx_s4.p4` — P4 stage-4 policer table
- `platform/rtos-sw/modules/nicmgr/src/{ipc.c,ipc.h,zrpc.c}` — zRPC plumbing

### Submodule (separate patch)
- `ainic-rtos` — Ben's PR #1350 (RAS CPER removal, ~23 KB savings)

---

## 10. Files / artifacts

| Path | Contents |
|---|---|
| `~/share/pic-rl-2026-06-05/` | All shareable files |
| `~/share/pic-rl-2026-06-05/ainic-rtos.patch` | Submodule patch (PR #1350) |
| `~/share/pic-rl-2026-06-05/README.md` | Consumer instructions |
| `~/share/pic-rl-2026-06-05/handoff_kenya_perf3_4_sweep_2026_06_05.md` | Kenya verification (§11 has the headline) |
| `~/share/pic-rl-2026-06-05/kenya_pic_rl_results.md` | Standalone kenya RL report |
| `~/share/pic-rl-2026-06-05/pic-rl-share.tar.gz` | Tarball of share package |
| `https://github.com/pradeept26/sw/tree/pic-rl-1.130-a` | sw repo branch |
| `/ws/pradeept/ws/usr/src/github.com/pensando/sw-2/ainic_fw_vulcano.tar` | Built firmware (matches branch tip) |
| `/ws/pradeept/ws/usr/src/github.com/pensando/sw-2/nic/build/x86_64/hw/rudra/vulcano/out/nicctl_bin/nicctl.bin` | Built nicctl (with `--lif`) |

---

## 11. Open follow-ups

| # | Task | Priority |
|---|---|---|
| 1 | Fix dcache filter[7] restore on `--disable` (see §7) | medium |
| 2 | Sanity-check rate divisor `/24000` against formal ASIC formula (Vishwas / silicon team) | low |
| 3 | Validate slot 4 in `scheduler_rl` isn't shared with another consumer | low |
| 4 | Land Ben's ainic-rtos PR #1350 so the submodule patch goes away | depends on Ben |
| 5 | Convert this branch into a real PR against `pensando/sw:1.130-a` after dcache fix | medium |
| 6 | Add unit test / DOL coverage for `vulcano_pic_rl_lif_program()` | low |
| 7 | Document the PIC RL feature in `nic/rudra/src/hydra/p4/p4plus-16/meta_roce/docs/` | low |

---

## 12. How to resume this work

```bash
# Get the source
cd /ws/pradeept/ws/usr/src/github.com/pensando/sw-2
git checkout pic-rl-1.130-a

# Get the submodule patch applied (if not already)
cd platform/rtos-sw/external/ainic-rtos
git apply ~/share/pic-rl-2026-06-05/ainic-rtos.patch

# Build
cd /ws/pradeept/ws/usr/src/github.com/pensando/sw-2
# /full-build vulcano hydra fw   (or)
make -f Makefile.build build-rudra-vulcano-hydra-ainic-fw

# Deploy to kenya/SMC and test
# See ~/share/pic-rl-2026-06-05/README.md for the apply + build flow
# See handoff_kenya_perf3_4_sweep_2026_06_05.md §11 for the verification recipe
```

To address the dcache bug:
1. Add the restore-on-disable in `vulcano_pic_rl_lif_program()`
2. Rebuild firmware
3. Reproduce: enable → disable → run ib_write_bw, expect no throughput sag (vs. ~7% with current code)
