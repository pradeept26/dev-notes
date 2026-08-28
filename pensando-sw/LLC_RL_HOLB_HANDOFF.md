# LLC Atomic Meter Rate Limiter — HOLB Fix Handoff

**Date:** 2026-08-27
**Author:** Pradeep Thangaraju
**Based on:** Gaurav Borker's `LLC_RATE_LIMITER_HANDOFF.md` (PR #119731)
**Branch:** `gborcar/sw:meter_rl_llc`
**Testbed:** kenya-perf-3 (10.30.52.66) ↔ kenya-perf-4 (10.30.52.75)

---

## Summary

Validated the LLC atomic meter-based rate limiter (RL) for resolving Head-of-Line Blocking
(HOLB) on 2×400G Vulcano. Found and fixed a critical init bug that prevented the P4 meter
tables from being programmed at runtime.

**Result:** HOLB confirmed reproduced at ~680 Gbps. With RL @ 392 Gbps/port: **775 Gbps**
(HOLB resolved). At 393 Gbps/port: returns to ~688 Gbps. Matches Gaurav's handoff exactly.

---

## Bug Found and Fixed

### Root Cause

`eth_rdma_impl_pic_rl_llc_meter_init()` was placed inside `eth_rdma_impl_init()`.
However `eth_rdma_impl_init()` is **never called at runtime** — only
`eth_rdma_impl_lif_init()` is called (once per LIF at driver load time). So the P4 table
base addresses for `pic_rl_meter_check_tbl` and the 4 peek tables were never programmed.
METER_UPDATE fired at address 0 → no throttling.

### Fix

Moved the call into `eth_rdma_impl_lif_init()` gated on `lif_id == 1` (primary RDMA LIF,
called exactly once):

```c
// lif_init.c — at end of eth_rdma_impl_lif_init()
if (eth_lif_id(lif) == 1) {
    sdk_ret_t rl_ret;
    NICMGR_TRACE_ERR("PIC RL LLC meter init: calling from lif_init (lif=%u)", eth_lif_id(lif));
    rl_ret = eth_rdma_impl_pic_rl_llc_meter_init();
    if (rl_ret != SDK_RET_OK) {
        NICMGR_TRACE_ERR("PIC RL LLC meter init failed from lif_init, err %u", rl_ret);
    }
}
```

Also required:
- Removed `static` from `eth_rdma_impl_pic_rl_llc_meter_init()` in `init.c`
- Added declaration to `rdma_pic_rl.h` + `#include "sdk/base.hpp"`

### Patch Location

```
sw-dev9.pensando.io:/home/pradeept/llc_rl_lif_init_fix.patch
```

Apply on top of `gborcar/sw:meter_rl_llc`:
```bash
git apply ~/llc_rl_lif_init_fix.patch
```

---

## Additional Fix: Debug Logs

Added per-table success logs to `eth_rdma_impl_pic_rl_llc_meter_init()` for verification.
After a successful boot you should see in the nicmgr log:

```
[00:00:38] PIC RL LLC meter init: calling from lif_init (lif=1)
[00:00:38] PIC RL LLC meter init: entered
[00:00:38] PIC RL LLC meter: meter_base=0x1016d1040 status_base=0x10164a400
[00:00:38] PIC RL LLC meter: meter_check_tbl programmed OK (UXDMA0+1, base=0x1016d1040)
[00:00:38] PIC RL LLC meter: peek_port0_tbl programmed OK (UXDMA0+1, base=0x1016d1040)
[00:00:38] PIC RL LLC meter: peek_port1_tbl programmed OK (UXDMA0+1, base=0x1016d1080)
[00:00:38] PIC RL LLC meter: peek_port2_tbl programmed OK (UXDMA0+1, base=0x1016d10c0)
[00:00:38] PIC RL LLC meter: peek_port3_tbl programmed OK (UXDMA0+1, base=0x1016d1100)
[00:00:38] PIC RL LLC meter init: ALL 5 tables programmed successfully
```

---

## Test Setup

**Testbed:** kenya-perf-3 (10.30.52.66) ↔ kenya-perf-4 (10.30.52.75)
**Firmware:** Built from `meter_rl_llc` branch + patch, flashed to both nodes
**Profile:** 2×400G (`device_config_rdma_2x400G_4`)
**Credentials:** root / docker

### Critical: RL Must Be on the Sender Node

The `pic_rl_meter_check_tbl` sits in the **TX pipeline** and only fires on `pred.req_tx`
(speculative send path). In `ib_write_bw`, the **client** is the sender. RL on the
receiver does nothing — it never fires `pred.req_tx` for data packets.

**Correct setup:**
- `perf-4` = client (sender) → **enable RL here**
- `perf-3` = server (receiver)

### ib_write_bw Command

**Server (perf-3, receiver):**
```bash
numactl --cpunodebind=netdev:enp195s0f3 ib_write_bw \
  -d rocep195s0f3 -m 4096 -s 1048576 --run_infinitely \
  -q 7 -x 1 --report_gbits \
  --planes=19.1.0.2,19.2.0.2 -D 1 --tclass=96 -t 32 -r 32
```

**Client (perf-4, sender with RL):**
```bash
numactl --cpunodebind=netdev:enp195s0f3 ib_write_bw \
  -d rocep195s0f3 -m 4096 -s 1048576 --run_infinitely \
  -q 7 -x 1 --report_gbits \
  --planes=19.1.0.1,19.2.0.1 -D 1 --tclass=96 -t 32 -r 32 \
  10.30.52.66
```

### Nicctl on perf-4 (for RL config)

Gaurav's custom nicctl.bin is at `/root/gaurav/nicctl.bin` on both nodes.

**Enable RL:**
```bash
cd /root/gaurav
./nicctl.bin debug update pipeline internal rate-limit \
  --lif 18 --enable \
  --rate-bps 392000000000 \
  --burst-bytes 256000 \
  --max-ports 2 \
  --window-lg2 4 \
  --bdf 0000:c1:00.0
```

**Check meter state:**
```bash
./nicctl.bin show pipeline internal rate-limit --lif 18 --port-id 0 --bdf 0000:c1:00.0
./nicctl.bin show pipeline internal rate-limit --lif 18 --port-id 1 --bdf 0000:c1:00.0
```

**Disable RL:**
```bash
./nicctl.bin debug update pipeline internal rate-limit \
  --lif 18 --disable --rate-bps 1 --burst-bytes 1 \
  --max-ports 2 --window-lg2 4 --bdf 0000:c1:00.0
```

### HBM Verification (direct reads)

```bash
# Meter entries (64 bytes each): tbkt at offset 0 (LE int64)
eth_dbgtool memrd 0x1016d1040 64   # port 0
eth_dbgtool memrd 0x1016d1080 64   # port 1

# Port status bytes: 0x00=green, 0x01=red (throttled)
eth_dbgtool memrd 0x10164a400 8
```

Note: tbkt reads from HBM may appear stale (LLC cache coherency) — use the port status
bytes instead to confirm RL is firing. Port status is written via regular `__memory_write_b`
(not LLC atomic) so it IS visible via HBM reads.

---

## Test Results

### Node Setup
```
perf-3: root@10.30.52.66  — server (receiver), credentials: root/docker
perf-4: root@10.30.52.75  — client (sender, RL enabled), credentials: root/docker
Firmware: /root/pradeept/ainic_fw_vulcano_meter_rl_llc.tar (on both nodes)
```

### Data

| Test | Config | BW | tbkt (port 0) | Port status |
|------|--------|----|----------------|-------------|
| Baseline | RL disabled | ~680 Gbps | N/A | 0x00 0x00 |
| RL enabled | 392 Gbps/port | **775 Gbps** | -137,121 | 0x00 0x01 |
| Sensitivity | 393 Gbps/port | ~688 Gbps | — | HOLB returns |

### PB OQ Depth (Vishwas's data — reference)

Without RL (HOLB present):
```
p0oq 0   q_3 = 104  (single port backed up severely)
p0oq16   q_3 = 0
```

With RL @ 392 Gbps (HOLB resolved):
```
p0oq 0   q_3 = 48   (balanced across both OQs)
p0oq16   q_3 = 39
```

---

## Known Issues / Future Work

From Gaurav's handoff doc (still open):

1. **9× token formula** — `bps_to_tokens_per_window()` uses `80e9` denominator instead
   of correct `8.8e9` (clock is 1.1 GHz). Gives 9× too many tokens at high window sizes.
   At `window_lg2=4` (16 cycles) the effect is small enough that RL still works. Would
   need fixing for larger window sizes or precise rate control.

2. **Packet length accounting** — `p4_intr.packet_len` is payload only (not wire size).
   ~2.5% under-accounting.

3. **Multi-path port blocking** — current S2 logic assumes single path per QP.

4. **HBM readback** — METER_UPDATE writes to LLC cache; `pal_mem_rd` reads HBM directly
   → reads appear stale. Not a bug — expected LLC behavior. Use port status bytes for
   verification instead.

---

## Files Modified (in patch)

| File | Change |
|------|--------|
| `nic/rudra/src/hydra/nicmgr/plugin/rdma/init.c` | Remove `static`, add entry/success/fail logs |
| `nic/rudra/src/hydra/nicmgr/plugin/rdma/lif_init.c` | **Core fix**: call `eth_rdma_impl_pic_rl_llc_meter_init()` from `eth_rdma_impl_lif_init()` on lif_id==1 |
| `nic/rudra/src/hydra/nicmgr/plugin/rdma/rdma_pic_rl.h` | Expose `eth_rdma_impl_pic_rl_llc_meter_init()` declaration |
