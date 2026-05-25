---
title: RCCL alltoall 512M Scale Test — Debugging Context
date: 2026-04-27
firmware: 1.117.10-a-3
branch: 1.117.10-a-3
cluster: 8-node GPU cluster (Austin CCS lab)
status: Active debugging — patched driver deployed, awaiting next failure with dmesg logging
---

# RCCL alltoall 512M Scale Test — Debugging Context

## Cluster Details

**8 nodes, 8 NICs per node, 8 GPUs per node = 64 ranks total**

| Hostname | IP | Role |
|---|---|---|
| smc300x-ccs-aus-gpuf276 | 10.235.200.44 | Head node (mpirun launched from here) |
| smc300x-ccs-aus-gpuf29f | 10.235.200.140 | |
| smc300x-ccs-aus-gpuf2d6 | 10.235.200.147 | |
| smc300x-ccs-aus-gpuf2bb | 10.235.200.52 | Failed on some iterations |
| smc300x-ccs-aus-gpuf2ac | 10.235.200.69 | Most frequent failure node |
| smc300x-ccs-aus-gpuf2ba | 10.235.200.71 | |
| smc300x-ccs-aus-gpucc5a | 10.235.200.134 | Has 9 NICs (extra at 0000:32:00.0), baseline rdma res = 9 |
| smc300x-ccs-aus-gpuf2ae | 10.235.200.50 | |

**SSH access:** `prthangar@<ip>` with StrictHostKeyChecking=no

**Per-NIC limits (from ibv_devinfo):**
- `max_qp = 8192` (but partitioned: 4096 per UDMA, 2 UDMAs per NIC)
- `max_cq = 8064`
- `max_ah = 8192`
- `max_mr = 32768`

**Firmware:** `1.117.10-a-3` on all NICs (includes all 3 backtrack fixes)

**NIC devices:** 8x `ionic_0` through `ionic_7` per node, PCIe BDF `0000:06:00.0` through `0000:e6:00.0`

## The Test

**Command:** `/apps/shared/systest/meta_8kqp_validation/logs/longevity_v2/alltoall_512M_cmd.sh`

Key RCCL parameters:
- `RCCL_IB_QPS_PER_CONNECTION=85`
- `NCCL_MAX_P2P_NCHANNELS=64`
- `NCCL_IB_QPS_PER_P2P=32`
- 64 ranks, alltoall_perf, 512MB message, 500 iterations per run
- `NCCL_DEBUG=INFO` enabled

Creates ~7,579–7,664 QPs per NIC per run (3,832 CTS + 3,832 data QP pairs).

## The Issue

**Symptom:** RCCL alltoall fails intermittently with:
```
NCCL WARN Call to ibv_create_qp failed with error No space left on device
```

**Failure pattern:**
- Non-deterministic: passes 2–8 consecutive iterations, then fails
- Failing node varies (mostly gpuf2ac/10.235.200.69, also gpuf2bb/10.235.200.52)
- Fails during QP connection setup phase (before any data flows)
- Zero NIC pipeline anomalies on failing iterations
- Zero CQE errors, zero firmware log errors

## Root Cause Analysis

### Where the failure happens

The ENOSPC originates in the **kernel RDMA driver**, not firmware.

**Call chain:**
```
ibv_create_qp()                                    [userspace libibverbs]
  → ibv_cmd_create_qp_ex2()                        [kernel uverbs]
    → ionic_create_qp()                            [ionic_controlpath.c:~3385]
      → ionic_get_qpid()                           [ionic_controlpath.c:145]
        → ionic_resid_get_shared()                  [ionic_res.c — ida allocator]
          → returns -ENOMEM                         [no free ID in range]
```

The firmware never sees the failed create — it's rejected before the admin command is sent.

### Per-UDMA QP ID partitioning (the likely root cause)

The installed driver (`/usr/src/ionic-26.03.3.001/`) partitions the QP ID space per UDMA:

```c
// ionic_get_qpid() in ionic_controlpath.c:145
size = dev->size_qpid / dev->udma_count;   // 8192 / 2 = 4096 per UDMA
base = size * udma_ix;                      // ud0: 0-4095, ud1: 4096-8191
bound = base + size;
rc = ionic_resid_get_shared(&dev->inuse_qpid, base, bound);
```

**Each UDMA has only 4096 QP ID slots, not 8192.**

The QP's UDMA is constrained by its CQ's UDMA (`udma_mask` in `ionic_create_qp`):
```c
udma_mask = BIT(dev->udma_count) - 1;           // start with both UDMAs
if (attr->send_cq)
    udma_mask &= to_ionic_vcq(attr->send_cq)->udma_mask;  // constrain to CQ's UDMA
if (attr->recv_cq)
    udma_mask &= to_ionic_vcq(attr->recv_cq)->udma_mask;
```

If the CQ is on ud0, the QP must go on ud0 — only 4096 slots.

**The test creates 3,832 data QPs per NIC — that's 93.4% of the 4096 per-UDMA limit.** Only 264 slots headroom. Any imbalance in CQ-to-UDMA mapping pushes one UDMA over 4096.

### What we've confirmed

1. **Not a firmware issue:** Zero pipeline anomalies, zero CQE errors, zero NIC log errors on failing iterations
2. **Not a host cleanup issue:** `rdma res` shows baseline (8-9 QPs) before every iteration; QP bitmap probe shows 8190 available after teardown
3. **Not requesting too many QPs:** RDMA stats show 7,490–7,632 creates per NIC (under 8192) on both passing and failing iterations — identical counts
4. **The failure is silent:** No dmesg, no firmware log — driver returns ENOMEM without logging (now fixed with patch)
5. **Backtrack anomalies are unrelated:** 30K+ SQ anomalies per node on PASSING runs; all QPs complete successfully (msn == ssn-1 verified on 3,772 QPs)

### Backtrack anomalies (separate from the RCCL failure)

The pipeline anomalies ("non zero backtrack ring1 producer index" + "CTS mismatch") seen on all runs are:
- Cosmetic residuals from PFC-triggered retransmission under congestion
- `bt_done=1` flag not cleared after backtrack completion
- `lsn` (CTS license count) > `lsn_rx` (actual data) due to duplicate CTSes from retransmitted packets
- Present on both passing and failing runs (30K+ per node)
- All 3,772 inspected QPs had `msn == ssn-1` (fully completed), `tx_psn == rexmit_psn == max_tx_psn`, `err_retry_ctr == 7/7`
- All 3 backtrack fixes present in firmware: fc55619 (MSN capping), 66a0246 (byte sharing), ca6c42e (dcache coherency)

## Driver Patch Deployed

**What:** Added `ibdev_warn` logging to `ionic_get_qpid()` when QP ID allocation fails.

**File:** `/usr/src/ionic-26.03.3.001/rdma/drv/ionic/ionic_controlpath.c`

**Change (after the for loop, before return):**
```c
if (rc)
    ibdev_warn(&dev->ibdev,
               "ionic_get_qpid: no ids for udma_ix %d, mask=0x%x, size=%d\n",
               udma_ix, udma_mask, dev->size_qpid / dev->udma_count);
```

**Status:** Built and installed via DKMS on all 8 nodes, modules reloaded. Active.

**Expected output on failure in dmesg:**
```
ionic ionic_X: ionic_get_qpid: no ids for udma_ix N, mask=0xM, size=4096
```

This tells us:
- Which `ionic_X` device ran out
- Which UDMA index (0 or 1) was full
- The `udma_mask` — whether both UDMAs were tried or only one

## Scripts and Tools

All on shared filesystem accessible from all nodes.

### Longevity test wrapper
**Path:** `/apps/shared/pradeept/run_alltoall_longevity.sh`
**Usage:** `/apps/shared/pradeept/run_alltoall_longevity.sh <num_iterations>`
**Run from:** 10.235.200.44

Features:
- Clears pipeline state before each iteration (`nicctl clear pipeline internal state`)
- Tracks live QPs via `rdma res` (per-device summary)
- Waits for QP drain between iterations (baseline=9 for .134's extra NIC)
- On failure: collects QP summary, QP used dump, dmesg, anomalies, hw_counters, NIC logs, RDMA stats, rdma res per node
- Stops on first failure
- Logs dir: `/apps/shared/pradeept/alltoall_longevity_<timestamp>/`

Output files on failure:
- `iter_N.log` — full RCCL output
- `iterN_errors.txt` — extracted RCCL error lines
- `iterN_qp_summary_<ip>.txt` — per-NIC QP counts (total/CTS/data)
- `iterN_qp_used_<ip>.txt` — all QP IDs (for per-UDMA analysis)
- `iterN_rdma_res_<ip>.txt` — kernel rdma res at capture time
- `iterN_dmesg_<ip>.txt` — kernel logs (includes our ionic_get_qpid logging)
- `iterN_anomalies_full_<ip>.txt` — pipeline anomalies
- `iterN_hw_counters_<ip>.txt` — non-zero RDMA hw counters
- `iterN_niclogs_<ip>.txt` — NIC firmware error logs
- `rdma_stats_iterN_before/after.txt` — cumulative RDMA stats
- `live_qps_iterN_immediate.txt` — rdma res snapshot right after test
- `results.txt` — pass/fail per iteration with anomaly counts

### QP bitmap probe tool
**Path:** `/tmp/probe_qp_limit` on all 8 nodes
**Usage:** `/tmp/probe_qp_limit <device_name> <max_attempts>`
**Example:** `/tmp/probe_qp_limit ionic_0 8192`

Creates QPs in a loop until failure, reports how many succeeded = available bitmap slots. Cleans up after itself. Currently commented out of the longevity script (replaced by dmesg logging).

### Driver patch script
**Path:** `/apps/shared/pradeept/patch_all_nodes.sh`

Copies patched source from .44 to all nodes, rebuilds DKMS, installs. Does NOT reload modules.

### Driver reload command
```bash
for ip in 10.235.200.44 10.235.200.140 10.235.200.147 10.235.200.52 10.235.200.69 10.235.200.71 10.235.200.134 10.235.200.50; do
  ssh -o StrictHostKeyChecking=no prthangar@$ip 'sudo rmmod ionic_rdma; sudo rmmod ib_peer_mem 2>/dev/null; sudo rmmod ionic; sudo modprobe ionic; sudo modprobe ib_peer_mem 2>/dev/null; sudo modprobe ionic_rdma'
done
```

### Driver source location
**DKMS source:** `/usr/src/ionic-26.03.3.001/` on each node
**Key files:**
- `rdma/drv/ionic/ionic_controlpath.c` — QP create/destroy, patched with logging
- `rdma/drv/ionic/ionic_res.c` / `ionic_res.h` — ida-based ID allocator
- `rdma/drv/ionic/ionic_ibdev.c` — device init, bitmap sizes

**Rebuild after changes:**
```bash
sudo dkms remove ionic/26.03.3.001 -k $(uname -r)
sudo dkms build -m ionic -v 26.03.3.001 -k $(uname -r)
sudo dkms install -m ionic -v 26.03.3.001 -k $(uname -r) --force
```

### Package location
**Bundle:** `/apps/shared/pradeept/images/ainic_bundle_1.117.10-a-3/host_sw_pkg/`
**Install:** `./install.sh` (full install including firmware)
**Driver tarball:** `ionic_driver/src/drivers-linux.tar.xz`

## Key Code References

### QP ID allocation (driver)
- `ionic_get_qpid()` — `/usr/src/ionic-26.03.3.001/rdma/drv/ionic/ionic_controlpath.c:145`
- Partitions 8192 IDs into 2 UDMAs of 4096 each
- `udma_mask` constrains which UDMA(s) the QP can use (derived from CQ affinity)
- Alternates starting UDMA via `next_qpid_udma_idx ^= udma_count - 1`

### QP create flow (driver)
- `ionic_create_qp()` — `ionic_controlpath.c:~3385`
- `udma_mask` is AND'd from send_cq, recv_cq, and userspace request
- If CQ is on one UDMA, QP is forced onto that UDMA

### QP destroy potential leak (driver)
- `ionic_destroy_qp()` — `ionic_controlpath.c:~3389`
- Line ~3406: `if (ionic_destroy_qp_cmd() fails) return rc;` — skips `ionic_put_qpid`/`ionic_put_ahid`
- Potential bitmap leak if firmware rejects destroy command

### QP create handler (firmware)
- `eth_rdma_impl_aq_qp_create_hdlr()` — `nic/rudra/src/pulsar/nicmgr/plugin/rdma/admincmd_handler.c:1442`
- Only reached if driver successfully allocates QP ID — not involved in ENOSPC failures

### Completion check (firmware P4)
- `rdma_req_rx_s4_sqcb1_wb.p4` line 174: `sqcb1.msn != p.ssn - 1` (SQ drain check)
- Correct completion verification: `msn == ssn - 1`, NOT `msn == tx_psn`

## Next Steps

1. **Run longevity test with patched driver** — `dmesg` will show `ionic_get_qpid: no ids for udma_ix N, mask=0xM, size=4096` on failure, confirming which UDMA is exhausted
2. **Analyze the udma_mask** — if `mask=0x1` or `mask=0x2` (single UDMA), it confirms CQ affinity is forcing QPs onto one UDMA
3. **If confirmed:** The fix is either:
   - Allow CQs to be created on both UDMAs (spread the load)
   - Increase per-UDMA QP limit
   - Have RCCL distribute CQs across UDMAs more evenly
4. **File a Jira** with the dmesg evidence showing per-UDMA exhaustion

## Previous Log Directories

| Directory | Iterations | Result | Notes |
|---|---|---|---|
| `alltoall_longevity_20260427_121754` | 1 | 1F | ENOSPC gpuf2ac, pre-script |
| `alltoall_longevity_20260427_131537` | 3 | 2P 1F | ENOSPC gpuf2ac iter3 |
| `alltoall_longevity_20260427_144314` | 1 | 1F | EINVAL gpuf2bb (GID table issue) |
| `alltoall_longevity_20260427_151153` | 9 | 8P 1F | ENOSPC gpuf2ac iter9, has rdma_res/qp_summary |
| `alltoall_longevity_20260427_173843` | 8 | 7P 1F | ENOSPC gpuf2bb iter8, pre-patch driver |
