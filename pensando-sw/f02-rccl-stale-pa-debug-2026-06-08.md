# F02 RCCL Hang — Stale NIC Translation Cache Debug (2026-06-08)

## Quick Summary

RCCL all_reduce hangs reproducibly on F02 (Helios-P Mini Rack) after first warmup AllReduce. Root cause traced to **NIC's internal translation cache holding a STALE PA from a previous RCCL run** — even though the control-plane KTE and Page Table are correctly populated for the current run, the NIC's S0 WQE-fetch translation hits the stale cached entry, DMAs from an unmapped PA, gets back 0xff, interprets that as a malformed WQE, triggers `spec_failure`, retries forever.

**Status**: Bug confirmed. Vijay's morning hypothesis (stale IOVA→PA) is correct. Vijay's private build with the `sqcb1.rsvd1` debug counter did NOT fix it — it only added instrumentation.

## Setup

- Cluster: ctheliosp-1b114-f02-1 ↔ ctheliosp-1b114-f02-2 (Helios-P 2×1P4G Meta MR)
- Failing card: NIC1 (`0001:01:00.0`) on each node — `roceP1p3s0f3`
- Card UUIDs:
  - f02-1 NIC1: `42424650-5132-3630-3930-304135000000` (LIF `02000070-0100-0000-4242-049081b18d60`, hw lif id 2, IP 192.168.1.6)
  - f02-2 NIC1: `42424650-5132-3630-3930-303741000000` (LIF `02000070-0100-0000-4242-049081b18958`, hw lif id 2, IP 192.168.1.20)
- FW: `1.130.0-a-6-dirty` on both NIC1s (Vijay's instrumented private build, adds `sqcb1.rsvd1` counter)
- Other NICs (2/3/4) on both nodes: stock `1.130.0-a-6`
- Asicmon binary: `1.130.0-a-10` (newer than the loaded FW)
- HugePages on both nodes: `HugePages_Total = 0` (4KB pages only)

## Access

- f02-1: `ssh gunar@srv20` → `ssh guramasam@ctheliosp-1b114-f02-1.amd.com` (Conductor key on srv20). `sudo` works passwordless.
- f02-2: `ssh gunar@srv20` → `sshpass -p amd123 ssh amd@ctheliosp-1b114-f02-2.amd.com`. `sudo -S` with password amd123.
- IMPORTANT: For `eth_dbgtool`, `capview`, `asicmon` use `sudo -E` and set `PAL_CARD_UUID=<card-uuid>` to scope to specific NIC. Both f02-1 and f02-2 — wait, **`eth_dbgtool` and `capview` only work on f02-2** (the dirty build patched their card-discovery). On f02-1 they fail with "no AMD NIC cards detected".

## Test Driver

- Script: `/apps/karthik/rccl-test_bkcrocm_BKC260413/prepare2N.sh` on f02-1
- LD_PRELOAD: `/apps/karthik/rccl/rocm-systems/projects/rccl/build/release/librccl.so`
- Test: `all_reduce_perf -b 8M -e 32M -f 2 -g 1 -n 10 -w 5 -N 1 -c 1`
- Simplified env: `NCCL_MAX_NCHANNELS=1`, `NCCL_IB_QPS_PER_CONNECTION=1`, `NCCL_PROTO=Simple`, `NCCL_ALGO=Ring`, `NCCL_IB_USE_INLINE=0`, `RCCL_CTS_OFFLOAD_ENABLED=0`, `RCCL_CTS_INLINE_DATA=0`, P2P/SHM/PXN disabled.
- Run from `/apps/karthik/rccl-test_bkcrocm_BKC260413/` with `sudo nohup bash ./prepare2N.sh > /home/guramasam/rccl_run_<ts>.log 2>&1 < /dev/null &`
- Test creates 2 QPs per side: **QP 2 = CTS**, **QP 3 = data**. QP 3 is the one that hangs.

## Failure Pattern (identical across runs)

1. RCCL init COMPLETE
2. Warmup AllReduce opCount 0-4 launched
3. NCCL "Posted send" lines: 4 WQEs posted to QP 3 (`pi_0 = 0x400` = 4 in big-endian display)
4. Log freezes, no completions
5. After ~22 min: `ionic_comp_msn:1567 cqe with error 2 for 0x1 (msn), qpid 3 cqid 3` → `IBV_WC_LOC_QP_OP_ERR(2)` → RCCL aborts

## Diagnostic Evidence

### nicctl anomalies (both nodes, QP 3 only):
```
[SQ 0003] - SQ ring pi: 0x4 != ci: 0x0 (WQEs pending)
[SQ 0003] - spec_failure active - pipeline in rollback (spec_sq_cindex=4, exp_sq_cindex=0, restart_ci=0, restart_posn=0, restart_msn=1)
[SQ 0003] - all paths inactive - no path can send (max_paths=8, num_inactive=8, congestion_state=1, qp_cwnd=0)
```

### SQCB QP3 (live, while hung):
- `va2pa_key = 0x1003` (for WQE-fetch VA→PA lookup)
- `pi_0 = 0x400` (= 4 WQEs posted), `spec_sq_cindex = 0x4`, `exp_sq_cindex = 0x0` (0 committed)
- `lg2_wqe_sz = 0x6` (64-byte WQEs)
- `wqe_ring_base = 0`, `wqe_entry_size = 0`, `wqe_ring_size = 0` (these are "ExpressDb only" — not used in Hydra normal path)
- `sq_on_host = 1`, `state = 4` (RTS), `lg2_sq_ring_sz = 0xa` (1024 entries)
- `spec_failure = 1` (currently rolling back)
- `num_color_mismatch = 0`, `qp_err_dis_inv_wqe_format = 0`, `qp_err_dis_inv_wqe_len = 0` (no error-disable triggered)
- `sqcb1.path_bitmap_0/1 = 0/0` (no active paths), `sqcb1.inactive_path_bitmap_0/1 = 0/0xff` (8 paths in inactive pool)
- `sqcb1.bootstrap_in_progress = 0`, `force_bootstrap = 0`, `num_ports = 1`

### asicmon -v during hang (f02-2 NIC1, UDMA0 S2 — THE smoking gun):
```
mpu 3 cyc=87380 inst=65536 CPI=1.33 phvs=10922 TBL_ID:8:100% pci 100%:lat=1199 tbl_addr=0x00000002120660c0 pc=0x00000000010b9228
mpu 4 cyc=87380 inst=65536 CPI=1.33 phvs=10922 TBL_ID:8:100% pci 100%:lat=1219 tbl_addr=0x0000000212066040 pc=0x00000000010b9228
mpu 5 cyc=87380 inst=65536 CPI=1.33 phvs=10922 TBL_ID:8:100% pci 100%:lat=1200 tbl_addr=0x0000000212066080 pc=0x00000000010b9228
```
**Three MPUs pinned at PC `0x010b9228` (the WQE-fetch action) doing PCIe reads at PA `0x212066040/080/0c0` (64B stride for WQE_1/2/3).**

This matches **EXACTLY** Vijay's morning observation:
```
mpu 3 ... tbl_addr=0x0000000212066100  pc=0x00000000010b9228
mpu 4 ... tbl_addr=0x0000000212066180  pc=0x00000000010b9228
mpu 5 ... tbl_addr=0x0000000212066100  pc=0x00000000010b9228
```
Same PC, same PA prefix `0x212066xxx`.

### Direct memory dump of NIC view (memrd):
```
$ eth_dbgtool memrd 0x212066040 256
212066040 : ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff
... all 256 bytes = 0xff
$ eth_dbgtool memreg_find 0x212066040
Cannot find region    ← NOT a known memreg
```

### Why spec_failure but no color mismatch (`num_color_mismatch=0`):
- All-0xff WQE: color bit = 1 (matches `spec_wqe_color = 1`) → color check PASSES
- All-0xff WQE: length field = enormous → S2 fires `last_spec_failed = 1` → rollback
- Loop: same address → same garbage → same fail → forever

### F02-1 also has secondary catastrophic stuck MPU (different bug, also surfaced):
```
mpu 1 cyc=67108863 inst=14 CPI=4793490.50 phvs=1048575 mhit=80% mmiss=20% pc=0x00000000010bd9c0
```
CPI = 4.8 million, phv counter saturated at 2^20-1, MPU dead-spinning at PC `0x010bd9c0`. Not the same WQE-fetch bug; possibly secondary effect of f02-2's hang starving f02-1's RX pipeline.

## Root Cause Validated via eth_dbgtool

User pointed me to validate WQE address chain via key-table → page-table. Process:

1. **Get the SQ's VA→PA key from SQCB**:
   ```
   sqcb0.va2pa_key = 0x1003 (for QP3 SQ)
   sqcb0.va2pa_key = 0x2003 (for QP3 RQ — RQ keys start at 0x2000)
   ```
   Per `nic/rudra/src/hydra/nicmgr/plugin/rdma/devcmd_handler.c:435-544` (`eth_rdma_impl_aq_configure_va2pa`):
   ```c
   case KEY_TO_TYPE_SQ:
       keytable_base = eth_lif_rdma_cq_count(lif);   // = 0x1000 = 4096
   keytable_id = keytable_base + q_id;               // = 0x1000 + 3 = 0x1003
   ```

2. **Which KTE table does WQE-fetch use?** Per `meta_roce_tx_s0.p4:35-45`:
   ```p4
   action _sqcb_stage_wqe_read(inout rdma_sqcb0_t d, bit<16> cindex) {
       pred.sqwqe = 1;
       p.sq_sge0_key.sq.key = d.va2pa_key;
       p.sq_sge0_key.sq.cmd = VA2PA_CMD_TO_TRANS_VA;   // ← TO-KTE, not regular KTE!
       p.sq_sge0_key.sq.va = RAW_TABLE_ADDR(0, 0, LIF_GROUP_ID(p.p4_intr_global.lif),
                                            (bit<64>)cindex << d.lg2_wqe_sz);
   }
   ```
   So WQE-fetch uses **TO-KTE table** (`VA2PA_CMD_TO_TRANS_VA = 7`), not the regular KTE. The eth_dbgtool command for it is `rdma_kte_to` (vs `rdma_kte` for regular MR keys).

3. **Dump TO-KTE entry 0x1003**:
   ```
   $ eth_dbgtool rdma_kte_to 2
       Index  host  t  s  qpid  lkey  ukey  ck  ac      fl  base-addr  s-offset  va-len  va-base
       1003    1    1  2     0    0     0    0 ------ ---  100038a00         0   65536        0
   ```
   ✓ Valid: state=2, host=1, type=1 (1-level PT), pt_base=`0x100038a00`, va_len=64KB (matches 1024 × 64B WQEs).

4. **Dump the page table at NIC HBM `0x100038a00`**:
   ```
   $ eth_dbgtool memrd 0x100038a00 128
   100038a00 : 66 56 c3 a1 02 00 00 00 66 76 5a ac 01 00 00 00
   100038a10 : 66 66 14 a2 02 00 00 00 66 e6 9a b8 02 00 00 00
   ...
   ```
   16 PTE entries, each 8 bytes, little-endian. Low 12 bits = flags (`0x666`), upper bits = page frame number.
   Decoded PAs:
   ```
   PTE[0]: 0x2a1c35000
   PTE[1]: 0x1ac5a7000
   PTE[2]: 0x2a2146000
   PTE[3]: 0x2b89ae000
   ...
   PTE[f]: 0x256f0a000
   ```
   16 PAs × 4KB = 64KB matches va_len. **NONE of these = `0x212066xxx`.**

5. **Expected NIC fetch PA** for cindex 0..3 (within first 4KB page → PTE[0]):
   - WQE_0 → `0x2a1c35000`
   - WQE_1 → `0x2a1c35040`
   - WQE_2 → `0x2a1c35080`
   - WQE_3 → `0x2a1c350c0`

6. **Actual NIC fetch PA** (from asicmon):
   - WQE_1 → `0x212066040`
   - WQE_2 → `0x212066080`
   - WQE_3 → `0x2120660c0`

**Mismatch: NIC reading `0x212066xxx`, PT says `0x2a1c35xxx`.** The PA the NIC uses is not in the current page table. It's a stale cached translation from a previous RCCL run.

## Root Cause

**NIC dcache / S0 translation cache holds STALE VA→PA mappings from a previous RCCL run that were NOT invalidated when the current run rewrote KTE[0x1003] / the page table at 0x100038a00.**

Specifically:
- KTE entries auto-allocated for QP CQ/SQ/RQ are at indices: CQ at 0..0xFFF, SQ at 0x1000..0x1FFF, RQ at 0x2000..0x2FFF.
- For RCCL data QP at qid=3 → SQ KTE[0x1003], RQ KTE[0x2003].
- Each create_qp call **rewrites** these KTE entries and writes a fresh PT.
- The NIC's internal cache that S0 uses for VA→PA lookup is NOT being invalidated correctly on KTE/PT rewrite — it returns stale PA from an earlier run.
- The stale PA `0x212066xxx` is from one of the FIRST RCCL runs of the day (per Vijay's morning observation — that PA was present then too).

## Why IB Tests Don't Hit This (INITIAL hypothesis — REFUTED at 11:13 UTC)

Initial guess was that IB doesn't hit the bug because it doesn't recreate QPs / uses different qids. **This was wrong.**

## Confirmation: IB ALSO fails — bug is QID-specific cache pollution

At 11:13 UTC, ran `run_ib_write_bw.sh crossnode --server F02-1 --client F02-2 --pairs P1-P1 --mem cpu --af ipv4 --dir unidir --iterations 5000 --skip-bringup --skip-precheck`.

**Same failure**:
```
ionic_comp_msn:1567: cqe with error 2 for 0x20 (msn), qpid 3 cqid 2
Completion with error at client
```

Identical `ionic_comp_msn:1567` MSN-layer error, `cqe with error 2`, **qpid 3** — same QP id whose translation cache is poisoned.

**Revised story**:
- The bug is **NOT RCCL-specific** — it's qid-specific cache pollution.
- Once qid=3's KTE (TO-KTE[0x1003]) translation cache is polluted in the NIC dcache (from earlier RCCL runs today that created/destroyed qid=3 with different host PAs), ANY workload that uses qid=3 hits the stale cache and fails identically.
- Earlier today IB sanity passed (per Slack ~07:00 IST) because the cache wasn't yet polluted for qid=3.
- ~5+ hours of RCCL runs polluted qid=3's translation cache → IB at qid=3 now also fails.
- This **simplifies** the diagnosis and removes the "IB works" outlier.

## Recovery

`nicctl clear pipeline internal state` only clears P4 pipeline state — NOT the deeper translation cache. To recover requires clearing the NIC's internal caches.

### ⚠️ Important: `nicctl reset card` is NOT safe on this build

Tested at 11:33 UTC on f02-1: `sudo nicctl reset card -b 0001:01:00.0` (NIC1 only). **Host went unreachable**, BMC also unreachable from srv20. Same failure Karthikeyan reported at 04:25 IST this morning — required AC cycle via BMC + bringup_crossnode script to recover.

**Conclusion: do NOT use `nicctl reset card` on this build until the host-hang issue is fixed.** Either:
- Use BMC-based AC cycle directly (heavier but works)
- Use Vijay's `axi_filters.txt` workaround (lighter, doesn't reset the card)

### Recovery options (ranked by safety)

1. **`axi_filters.txt` via capview** — modifies AXI invalidation filter slots; does NOT reset card. May flush stale cache or prevent future pollution. The file is on f02-2 at `/tmp/axi_filters.txt`. Re-apply:
   ```
   PAL_CARD_UUID=42424650-5132-3630-3930-303741000000 capview \
     -f /etc/amd/ainic/vulcano/rudra/hydra/capviewdb.bin < /tmp/axi_filters.txt
   ```
2. **BMC AC cycle** (requires BMC access — Madan/Amar handle this) → followed by `bringup_crossnode_*.sh`
3. **`nicctl reset card`** — DEPRECATED for this build; hangs host. Do not use.

## Vijay's Morning Workaround

`/tmp/axi_filters.txt` (still on f02-2):
```
secure on
fset su0_su_invf0_filter_addr_ctl_value__S[12] .valid=0
fset su0_su_invf1_filter_addr_ctl_value__S[12] .valid=0
fset su0_pics_p4invf_filter_addr_ctl_value__S[11] .valid=0
fset su1_su_invf0_filter_addr_ctl_value__S[13] .valid=0
fset su1_su_invf1_filter_addr_ctl_value__S[13] .valid=0
fset su1_pics_p4invf_filter_addr_ctl_value__S[12] .valid=0
```
These are **AXI invalidation filter slot disables** — directly targeting the cache-invalidation issue. To re-apply:
```
PAL_CARD_UUID=42424650-5132-3630-3930-303741000000 capview \
  -f /etc/amd/ainic/vulcano/rudra/hydra/capviewdb.bin < /tmp/axi_filters.txt
```

## Key Source File Pointers

- `nic/rudra/src/hydra/p4/p4plus-16/meta_roce/tx/meta_roce_tx_s0.p4:35-45` — `_sqcb_stage_wqe_read` action using `VA2PA_CMD_TO_TRANS_VA` and `va2pa_key`
- `nic/rudra/src/hydra/p4/p4plus-16/meta_roce/tx/meta_roce_tx_s1.p4` — S1 WQE decode with color check
- `nic/rudra/src/hydra/p4/p4plus-16/meta_roce/include/rdma_sqcb.p4:31` — `va2pa_key` field definition (24-bit)
- `nic/rudra/src/hydra/p4/p4plus-16/meta_roce/docs/02-tx-pipeline.md` — TX pipeline narrative (sections 1-2)
- `nic/rudra/src/hydra/p4/p4plus-16/meta_roce/docs/06-debugging.md` — Debug runbook (anomaly tree)
- `nic/rudra/src/hydra/nicmgr/plugin/rdma/devcmd_handler.c:435-544` — `eth_rdma_impl_aq_configure_va2pa` (allocates va2pa_key for CQ/SQ/RQ)
- `nic/rudra/src/hydra/nicmgr/plugin/rdma/admincmd_handler.c:951,1005,2177,2207,2299-2301,3438-3439` — create/destroy QP paths setting/clearing va2pa_key
- `platform/tools/eth/main.cc:280-329` — eth_dbgtool command list including `rdma_kte`, `rdma_kte_to`, `rdma_pte`, `memrd`, `memreg_find`
- `nic/p4plus/p4-16/include/va2pa_types_salina.p4:125-134` — KTE struct definition and size (64 bytes)
- `nic/rudra/src/hydra/p4/p4plus-16/rdma/include/rdma_va2pa.h:60-77` — KTE union with probe formats
- PC `0x010b9228` (WQE-fetch action) — to be looked up against the dirty FW build's symbol map for confirmation
- PC `0x010bd9c0` (f02-1 stuck MPU) — separate symptom, same lookup needed

## Diagnostic Commands Cheat Sheet (for next session)

```bash
# Check current anomalies (both nodes)
sudo nicctl show pipeline internal rdma anomalies

# Full SQCB raw for QP3
LIF=02000070-0100-0000-4242-049081b18958     # f02-2 NIC1 LIF
sudo nicctl show rdma queue-pair --raw --lif $LIF --queue-pair-id 3

# Card UUID for PAL_CARD_UUID
CARD=42424650-5132-3630-3930-303741000000    # f02-2 NIC1

# eth_dbgtool dumps (f02-2 only)
sudo -E env PAL_CARD_UUID=$CARD eth_dbgtool rdma_kte_to 2 | grep -E "^[ ]+[0-9a-f]+ "
sudo -E env PAL_CARD_UUID=$CARD eth_dbgtool memrd 0x100038a00 128       # PT for SQ3
sudo -E env PAL_CARD_UUID=$CARD eth_dbgtool memrd <suspect-PA> 256      # check what NIC sees there
sudo -E env PAL_CARD_UUID=$CARD eth_dbgtool memreg_find <addr>

# Live asicmon -v during hang
sudo -E env PAL_CARD_UUID=$CARD asicmon -v | grep "pc=0x00000000010b9228"

# Cleanup
sudo nicctl clear pipeline internal state
sudo pkill -9 -f mpirun
sudo pkill -9 -f all_reduce_perf
```

## Open Investigation Items

1. **Apply Vijay's `axi_filters.txt` workaround** and re-run RCCL to confirm whether disabling specific invalidation filters clears the hang.
2. ~~**Card reset test**~~ — DONE 2026-06-08 ~12:20 UTC. f02-1 NIC1 AC-cycled, came back clean. ALL anomalies cleared on f02-1. `nicctl reset card` hangs the host on this build (needs BMC AC cycle).
3. **Resolve PC `0x010b9228`** to a source line by mapping against the dirty FW's symbol table.
4. ~~**Compare with IB test post-RCCL-hang**~~ — DONE. IB test (`run_ib_write_bw.sh crossnode P1-P1`) at 11:13 UTC also failed with `qpid 3 cqe with error 2`, confirming bug is qid-specific.
5. **Look at exact KTE/PT writeback path** in admincmd_handler.c / devcmd_handler.c for any missing cache-invalidation calls.
6. **Check `eth_rdma_os_impl_asicpd_p4plus_invalidate_cache`** — this is the cache invalidation called after KTE writes (`devcmd_handler.c:371`). Verify it's being called and covering the right ranges.

## Conclusive Confirmation Test (12:52 UTC)

After f02-1 AC cycle + bringup + verified clean, ran `ib_write_bw -q 8` between f02-1 (clean) and f02-2 (still polluted at qid=3 after `nicctl clear pipeline state`).

8 QPs allocated at qids: 0x0002, 0x0003, 0x0004, 0x0005, 0x0800, 0x0801, 0x0802, 0x0803.

**Test failed**: `scnt=6905, ccnt=6242` (663 sends without completions). Anomalies on f02-2:

```
[SQ 0003] - requester TX error-disabled: 0x20 (inv_wqe_format)
[SQ 0003] - SQ ring pi: 0x9f != ci: 0x0 (WQEs pending)
[SQ 0003] - spec_failure active - pipeline in rollback
[SQ 0003] - all paths inactive - no path can send
```

**ONLY QP at qid=3 failed**; the other 7 QPs (qids 2, 4, 5, 2048-2051) worked normally. f02-1 anomalies: EMPTY.

This **definitively confirms**:
- ✅ Bug is qid-specific cache pollution at TO-KTE entry 0x1003
- ✅ Pollution survives `nicctl clear pipeline internal state` (kept poisoning new QPs at qid=3 long after the original RCCL run was killed)
- ✅ Only a full card reset (AC cycle via BMC) clears the NIC's internal translation cache
- ✅ AC cycle works (f02-1 clean post-cycle)
- ✅ f02-2 NIC1 needs AC cycle before RCCL can succeed

## Recovery Procedure (verified working for f02-1, same for f02-2)

```bash
# From a node that can reach the target's BMC (e.g., f02-1 can reach f02-2's BMC at hostname)
ssh root@bmc-ctheliosp-1b114-f02-X.amd.com   # password: 0penBmc

# 1. AC cycle — disconnects standby + DC, then powers BMC back up
mfg-tool power-control -p 0 -a cycle -s standby

# 2. Wait for BMC to come back (~90 s — BMC reboots too)
# 3. Once BMC is up, wait for i2cdump byte 0x30 to transition 0x07 → 0x09 (ready-to-DC-on)
i2cdump -y -f -y 6 0x20 | grep ^30:
# (Initial 0x07 = "do not DC on yet"; 0x09 = "ready to DC on")

# 4. Issue DC on
mfg-tool power-control -p 0 -a on

# 5. Wait for host boot (~3-4 min)
# 6. SSH back to host, run bringup
bash /apps/shared/ib_tests/bringup/bringup_crossnode_f02-X.sh

# 7. Verify
sudo nicctl show pipeline internal rdma anomalies   # should be EMPTY
sudo nicctl show rdma queue-pair --summary          # should be 0 QPs
```

## BMC Access Notes (verified 2026-06-08)

- BMC credentials: `root` / `0penBmc` (per RDCSG-McNabb.pdf)
- BMC reachability:
  - **NOT reachable from srv20** (different network segment)
  - **f02-2 → bmc-ctheliosp-1b114-f02-1.amd.com** works (resolves to 10.5.236.43, ping OK, ssh OK)
  - **f02-1 → bmc-ctheliosp-1b114-f02-2.amd.com** works (resolves to 10.5.236.65, ping OK, ssh OK)
- So as long as one node is up, the other's BMC is accessible. **Never reset both nodes simultaneously** — would lose the BMC jump path.

## Quirks observed

- `ib_write_bw` server side reported "Couldn't listen to port 18516" on first attempt with port 18516. Switching to 19006 fixed it. Likely some stale binding.
- `nicctl clear pipeline internal state` does NOT wipe netdev IPs (verified). But our earlier `--skip-bringup` IB script run somehow lost IPs on f02-1 — root cause unclear, may have been the wrapper's kill logic. Workaround: re-run `set_ip_f02-X.sh` after any IB script invocation that complains.
- `bringup_crossnode_f02-X.sh` may complete with exit 0 but routes still missing from `intf*_table` — workaround: run `set_ip_f02-X.sh` directly to force route re-adds (idempotent — gives `RTNETLINK answers: File exists` for existing).
- After AC cycle, IPs on netdevs sometimes don't come back after bringup_crossnode_*.sh — need to run `set_ip_f02-X.sh` manually.
- `nicctl reset card` hangs the host on this build — confirmed on BOTH f02-1 and f02-2. Always use BMC AC cycle.

## CONCLUSIVE PROOF (2026-06-08 ~14:48 UTC)

After full AC cycle of BOTH nodes + correct amdgpu modprobe (`gpu_recovery=0 discovery=2 ip_block_mask=0x4ff`), RCCL `all_reduce_perf -b 8M -e 32M -f 2 -g 1 -n 10 -w 5 -N 1 -c 1` was launched. The original bug (qid=3 cache pollution causing `cqe with error 2` / spec_failure) is **conclusively fixed**.

### QP states post-RCCL warmup (both f02-1 and f02-2 NIC1)

| Metric | Before fix | After fix |
|---|---|---|
| Anomalies | `[SQ 0003] spec_failure, err-disabled, all paths inactive` | **EMPTY** |
| Queue state QP3 | RTS/RTS but stuck | RTS (idle) |
| SQ ring PI/CI | 4/0 (stuck) | **4/4 (processed)** |
| MSN / BMSN | 1/1 (stuck) | 5/5 (advancing) |
| ACK MSN | 0 | **4 (all ACKed)** |
| Active paths | 0/8 inactive | 1/8 (bootstrapped) |
| Congestion state | fast-start (stuck) | aimd (real traffic) |
| QP CWND | 0 | 4 (window opened) |
| RTT QP | 0 | 1-2 µs (measured) |
| RCCL log status= | `status=2 IBV_WC_LOC_QP_OP_ERR` (every time) | **`status=0`** (success) |

### What actually transferred

During the warmup phase:
- Each side's QP 3 sent 4 RDMA WRITEs, all ACK'd by peer
- Each side's QP 2 received 5 CTS messages (one per warmup iteration, `-w 5`)
- Path bootstrapped, AIMD active, CWND opened

### New unrelated hang surfaced (not the original bug)

After completing the warmup batch, RCCL did not proceed to the actual benchmark iterations (`-n 10`). GPU went to 0% activity, log frozen, mpirun still running. No NIC anomalies — this is a **higher-layer issue** (RCCL/GPU coordination, possibly the custom `librccl.so`, or ROCm/HIP issue with the modprobe options). **Separate debug session needed; not blocking the war-room headline finding.**

#### Deep dive via strace + GDB (2 independent reproductions)

`strace -c` on the spinning `all_reduce_perf` PID showed **100% of syscalls are `sched_yield`** (~500K/sec). GDB attached:

**Main thread (LWP 32315, run 1; LWP 37135, run 2)** — spinning in `sched_yield`:
```
sched_yield ← testStreamSynchronize ← TimeTest ← AllReduceRunTest ← threadRunTests ← run ← main
```
`testStreamSynchronize` from rccl-tests calls `hipStreamSynchronize` and yields while polling.

**Thread 2 (LWP 32333 / 37183)** — blocked in HSA signal wait (the *actual* hung thread):
```
ioctl ← hsakmt_ioctl ← hsaKmtWaitOnMultipleEvents_ExtCtx ← hsaKmtWaitOnEvent_Ext
     ← rocr::core::InterruptSignal::WaitRelaxed
     ← rocr::core::InterruptSignal::WaitAcquire
     ← rocr::HSA::hsa_signal_wait_scacquire
     ← libamdhip64.so (hipStreamSynchronize internals)
```

**Other threads** all in normal idle states:
- `ibv_get_async_event` (RDMA async event readers — no errors fired) — confirms NIC is healthy
- `ncclProxyProgress` spinning idle (waiting for GPU to finish so it can submit more work)
- `ncclProxyService`/`UDS` (RCCL proxy services idle)
- HSA `AsyncEventsLoop` (background)

**Conclusion:** GPU was submitted a kernel (likely the AllReduce ring reduction or a DMA copy), and the host-side `hipStreamSynchronize` is blocked waiting for a GPU completion signal that **never fires**. Possible causes:
1. GPU kernel deadlock (kernel running but not completing)
2. Lost interrupt/signal back to host (GPU finished, signal dropped)
3. `amdgpu modprobe` option `ip_block_mask=0x4ff` disables IP blocks possibly needed for signal/interrupt delivery
4. HSA queue corruption

Recommended next debug: try `modprobe amdgpu gpu_recovery=0 discovery=2` (without `ip_block_mask=0x4ff`); check `dmesg` for GPU errors; check `amd-smi process` for hung GPU work; look at `/sys/class/kfd/kfd/topology/` queue states.

### Reproducibility

The GPU-layer hang **reproduces deterministically** — verified across 2 RCCL invocations with identical strace patterns (100% sched_yield, ~500K/sec) and identical GDB stacks blocked at the same HSA `InterruptSignal::WaitAcquire` callsite. The NIC stays healthy across both (anomalies empty, QP3 PI/CI=4/4 each time).

### Bottom line for the F02 war-room

**The qid-specific NIC translation-cache pollution bug Vijay diagnosed this morning is the root cause of every RCCL hang seen today. AC cycle clears it. Multiple back-to-back IB tests pass at line rate (606 Gb/s). RCCL CTS+data exchange now completes with status=0 (was status=2 before). The remaining "RCCL not progressing past warmup" is a separate, higher-layer issue unrelated to the NIC dataplane.**

### Action items for product team

1. **Root cause the cache invalidation path** — when KTE/PT entries at the same qid slot are rewritten between QP create/destroy cycles, the NIC's internal translation cache (the dcache/PICS path used by S0 WQE-fetch via `VA2PA_CMD_TO_TRANS_VA`) doesn't get invalidated. Investigate `eth_rdma_os_impl_asicpd_p4plus_invalidate_cache` (`devcmd_handler.c:371`) — does its address range cover the TO-KTE pages?
2. **Fix `nicctl reset card` host hang** — both f02-1 and f02-2 hang when the command is issued. Should be a NIC-only operation; PCIe rescan should NOT take down the host kernel.
3. **Vijay's `axi_filters.txt` workaround** — investigate if disabling certain invalidation filters is a legitimate workaround for the cache invalidation bug, or if it just masks the symptom.
4. **PC `0x010b9228`** in the dirty FW build is the WQE-fetch action that does the stale PA reads. Resolve to source line + confirm it's the `_sqcb_stage_wqe_read` action in `meta_roce_tx_s0.p4`.
