# F02 RCCL Debug — Handoff Document

**Date:** 2026-06-08 (EOD)
**Outgoing:** Pradeep Thangaraju
**Session goal:** Root-cause RCCL hang on Helios-P F02 Meta MR

---

## Status as of handoff

| Item | State |
|---|---|
| **Original RCCL hang (qid=3 cache pollution)** | ✅ Root-caused and validated. Workaround: BMC AC cycle. |
| **Underlying FW defect (cache invalidation)** | ❌ Open — needs FW investigation/fix |
| **Setup state right now** | Both nodes UP. f02-1 uptime ~1h, f02-2 uptime ~50min. NIC1 on both = `1.130.0-a-6-dirty` (Vijay's debug build). |
| **RCCL test runs** | Hung at GPU layer (separate, new issue). Last hung process may still be on f02-1. Recommend kill before next test. |
| **Slack channel** | #f02-rccl-run — summary posted at https://pensandoteam.slack.com/archives/C0B8WTQD6A0/p1780933690229809 |

---

## Cluster

- **Hardware:** Helios-P F02 Meta Mini Rack, 2 compute trays × 1P4G (1 CPU + 4 MI450 GPUs each), 4 Mortaro NICs per tray, scale-out switch
- **Nodes:**
  - `ctheliosp-1b114-f02-1.amd.com` (10.5.236.25 / OS IP 10.5.236.92)
  - `ctheliosp-1b114-f02-2.amd.com` (10.5.236.52 / OS IP 10.5.236.109)
- **NIC under test:** NIC1 (`0001:01:00.0`) on each node — `roceP1p3s0f3`, `enP1p3s0f3`
  - f02-1 NIC1 UUID: `42424650-5132-3630-3930-304135000000`, LIF `02000070-0100-0000-4242-049081b18d60`, IP 192.168.1.6
  - f02-2 NIC1 UUID: `42424650-5132-3630-3930-303741000000`, LIF `02000070-0100-0000-4242-049081b18958`, IP 192.168.1.20
- **FW:** `1.130.0-a-6-dirty` (Vijay's instrumented build with `sqcb1.rsvd1` debug counter). Other 3 NICs on each node = stock `1.130.0-a-6`.

---

## Access

| Path | Notes |
|---|---|
| `gunar@srv20` | Jump host (Conductor access) |
| `gunar@srv20` → `guramasam@f02-1.amd.com` | Conductor SSH key. ⚠️ **Was denied at times today** — Conductor reservation may need renewal periodically |
| `gunar@srv20` → `sshpass -p amd123 amd@f02-2.amd.com` | Always worked today |
| `sshpass -p amd123 amd@f02-1.amd.com` | Sometimes works (depends on sshd PasswordAuth state, intermittent) |
| BMC f02-1: `bmc-ctheliosp-1b114-f02-1.amd.com` | Internal mgmt IP 10.5.236.43, NOT reachable from srv20 — reach via f02-2 |
| BMC f02-2: `bmc-ctheliosp-1b114-f02-2.amd.com` | Internal mgmt IP 10.5.236.65, NOT reachable from srv20 — reach via f02-1 |
| BMC credentials | user `root`, pw `0penBmc` |

**Critical:** BMCs only reachable via the OTHER node. **Never AC cycle both nodes simultaneously** — lose the jump path.

---

## Key documents

| File | Contents |
|---|---|
| `~/dev-notes/pensando-sw/f02-rccl-stale-pa-debug-2026-06-08.md` | Full debug analysis (this file): all commands, evidence, code traces, recovery procedure |
| `~/dev-notes/pensando-sw/f02-rccl-handoff-2026-06-08.md` | This handoff |
| `~/RDCSG-McNabb.pdf` | Cluster documentation (IPs, BMC, hardware) |
| `~/bringup-080626-115810.pdf` | BMC power cycle procedure (i2cdump states, mfg-tool commands) |

---

## Test driver locations (on cluster)

| File | Purpose |
|---|---|
| `/apps/karthik/rccl-test_bkcrocm_BKC260413/prepare2N.sh` | RCCL all_reduce launcher (driven from f02-1) |
| `/apps/karthik/rccl/rocm-systems/projects/rccl/build/release/librccl.so` | Custom RCCL with qpsharing — LD_PRELOAD'd by prepare2N.sh |
| `/apps/pharraud/opt/rccl-tests/rccl-test_bkcrocm_BKC260413/bin/all_reduce_perf` | rccl-tests binary |
| `/apps/shared/ib_tests/test_scripts/run_ib_write_bw.sh` | Full IB sanity wrapper |
| `/apps/shared/ib_tests/bringup/bringup_crossnode_f02-{1,2}.sh` | Node bringup (run after any AC cycle) |
| `/apps/shared/ib_tests/bringup/set_ip_f02-{1,2}.sh` | Re-set IPs/routes only (idempotent) |
| `/apps/shared/ib_tests/test_results/` | Persistent test results dir |

---

## Today's findings (1-paragraph recap)

NIC's internal S0 VA→PA translation cache (used by `VA2PA_CMD_TO_TRANS_VA` for WQE fetch) holds a stale PA from a previous QP-create cycle. When a new QP at the same qid (e.g. qid=3) is created and the KTE/PT entries at that slot are rewritten, the cache invalidation does NOT cover the TO-KTE pages → NIC keeps reading the old PA on subsequent runs → PCIe read of unmapped PA returns 0xff → spec_failure loop → `cqe with error 2` after timeout. Affects ANY RDMA workload on the polluted qid, not just RCCL (proven by IB test failing the same way). `nicctl clear pipeline state` does NOT clear it; only NIC SoC reset does. Verified on both nodes with full BMC AC cycle. After AC cycle, 7 IB tests pass cleanly (peak 1104 Gb/s bidir), RCCL CTS+data exchange completes with `status=0` instead of `status=2 IBV_WC_LOC_QP_OP_ERR`.

---

## What's still open

### 1. FW defect — needs root-cause + fix
- Where: cache invalidation path that should fire when KTE/PT entries are rewritten via `eth_rdma_aq_kte_write` / `eth_rdma_aq_pte_write`
- Specific function to investigate: `eth_rdma_os_impl_asicpd_p4plus_invalidate_cache` (`nic/rudra/src/hydra/nicmgr/plugin/rdma/devcmd_handler.c:371`)
- Question: Does the invalidation range cover the TO-KTE pages? Is it the right cache being invalidated?
- Vijay's `axi_filters.txt` workaround (disabling `su0/su1_invf*[12]/[13]` and `pics_p4invf[11]/[12]`) suggests specific invalidation filter slots may be misconfigured

### 2. PC `0x010b9228` source-line resolution
- This is the WQE-fetch action that does the stale PA reads
- Likely `_sqcb_stage_wqe_read` in `nic/rudra/src/hydra/p4/p4plus-16/meta_roce/tx/meta_roce_tx_s0.p4` (line 35-45)
- Confirm by mapping against the dirty FW build's symbol map (would need access to Vijay's build artifacts)

### 3. New RCCL hang at GPU layer (NOT NIC)
- `hipStreamSynchronize` blocks on HSA InterruptSignal::WaitAcquire that never fires
- Stack trace and syscall pattern deterministic across 3 RCCL runs after NIC fix
- Suspect: `modprobe amdgpu gpu_recovery=0 discovery=2 ip_block_mask=0x4ff` — `ip_block_mask=0x4ff` disables some GPU IP blocks; one of them might be needed for proper signal/interrupt delivery
- Hand to ROCm/HIP team

### 4. NIC3 enumeration intermittent
- After AC cycle, NIC3 (`0003:01:00.0`) sometimes doesn't show in lspci
- Same morning issue Karthikeyan saw at 04:25 IST
- Hardware/PCIe issue at slot 3, doesn't affect NIC1 (the one we test on)

---

## Procedures cheat sheet

### Run RCCL
From f02-1:
```bash
cd /apps/karthik/rccl-test_bkcrocm_BKC260413
sudo bash ./prepare2N.sh 2>&1 | tee /tmp/rccl_$(date +%H%M%S).log
```

### Run IB sanity (manual)
**Server (f02-1):**
```bash
sudo ib_write_bw -d roceP1p3s0f3 -x 1 -F --report_gbits -s 65536 -n 1000 -q 8 \
    --bind_source_ip 192.168.1.6 -p <PORT>
```
**Client (f02-2):**
```bash
sudo ib_write_bw -d roceP1p3s0f3 -x 1 -F --report_gbits -s 65536 -n 1000 -q 8 \
    --bind_source_ip 192.168.1.20 -p <PORT> 192.168.1.6
```
Use a fresh `<PORT>` each run (e.g., 19060, 19061, ...) to avoid stale-binding issues.

For bandwidth curve: add `-a -n 10000` and drop `-s 65536`.
For bidir: add `-b`.

### Run IB sanity (script — does both sides via SSH)
```bash
sudo bash /apps/shared/ib_tests/test_scripts/run_ib_write_bw.sh \
    crossnode --server F02-1 --client F02-2 --pairs P1-P1 \
    --mem cpu --af ipv4 --dir unidir --iterations 5000
```

### Check NIC state
```bash
sudo nicctl show pipeline internal rdma anomalies      # any QP errors?
sudo nicctl show rdma queue-pair --summary             # how many QPs alive
LIF=02000070-0100-0000-4242-049081b18958              # f02-2 NIC1 LIF
sudo nicctl show rdma queue-pair --status --lif $LIF --queue-pair-id 3
sudo nicctl show rdma queue-pair --raw --lif $LIF --queue-pair-id 3 | less
```

### Diagnose stale PA bug (if symptoms return)
```bash
# 1. Anomalies will show:
#    [SQ 0003] - spec_failure active - pipeline in rollback
#    [SQ 0003] - all paths inactive

# 2. Check what NIC is reading via asicmon
source /etc/profile.d/amd_ainic_user_profile_update.sh
PAL_CARD_UUID=42424650-5132-3630-3930-303741000000 \
    sudo -E asicmon -v 2>&1 | grep "pc=0x00000000010b9228"
# → look at tbl_addr column — if it's NOT in the current PT, cache is polluted

# 3. Walk SQ → KTE → PT to confirm
LIF=02000070-0100-0000-4242-049081b18958
sudo nicctl show rdma queue-pair --raw --lif $LIF --queue-pair-id 3 | grep va2pa_key
# → expect 0x1003 for QP3 SQ

PAL_CARD_UUID=... sudo -E eth_dbgtool rdma_kte_to 2 | grep "^[ ]*1003 "
# → shows pt_base for SQ QP3

PAL_CARD_UUID=... sudo -E eth_dbgtool memrd <pt_base> 128
# → shows actual PTE entries (decode as 64-bit LE)
```

### Recovery: BMC AC cycle
```bash
# From a node that can reach the target BMC (f02-2 reaches f02-1's BMC and vice versa)
sshpass -p 0penBmc ssh root@bmc-ctheliosp-1b114-f02-X.amd.com bash -c '
  date
  mfg-tool power-state
  mfg-tool power-control -p 0 -a cycle -s standby
'
# wait ~90s for BMC reboot
# poll: i2cdump -y -f -y 6 0x20 | grep ^30:
# wait until byte 0x30 transitions 0x07 → 0x09

# Then DC on:
sshpass -p 0penBmc ssh root@bmc-... mfg-tool power-control -p 0 -a on

# Wait ~3-4 min for host boot
# Once SSH back, on the host:
sudo modprobe amdgpu gpu_recovery=0 discovery=2 ip_block_mask=0x4ff
sudo bash /apps/shared/ib_tests/bringup/bringup_crossnode_f02-X.sh
sudo bash /apps/shared/ib_tests/bringup/set_ip_f02-X.sh    # idempotent — fixes routes if bringup missed

# Verify:
sudo nicctl show pipeline internal rdma anomalies   # should be empty
sudo nicctl show rdma queue-pair --summary          # should be 0 QPs
ping -c 2 -I 192.168.1.X 192.168.1.Y                # cross-node
```

### Diagnose GPU hang (the new issue, post-NIC-fix)
```bash
PID=$(pgrep -f all_reduce_perf | head -1)

# Quick: syscall pattern
sudo timeout 3 strace -c -p $PID 2>&1 | tail -10
# Expected pattern: ~500K sched_yield/3s = 100% spin

# Stack traces:
sudo gdb -p $PID -batch \
    -ex "set pagination off" \
    -ex "info threads" \
    -ex "thread apply all bt 20" \
    -ex "quit" 2>&1 | less

# Look for:
#   Thread 1: sched_yield ← testStreamSynchronize ← TimeTest
#   Thread 2: hsaKmtWaitOnMultipleEvents_ExtCtx ← InterruptSignal::WaitAcquire ← libamdhip64.so
```

---

## Contacts (from today's Slack)

- **Vijay Sampath** — RDMA dataplane / FW expert. Diagnosed stale IOVA→PA pattern in the morning.
- **Karthikeyan Arumugam** — RCCL/IB testing. Drove most morning debugging until late evening (UTC).
- **Amar Eshappa Setra** — Setup/access management, BMC ops.
- **Madan Easwaramoorthy** — BMC operations, AC cycle recoveries.
- **Ganesh Dontula Venkata** — Tracking for execs, channel manager.
- **Balakrishnan Raman** — Channel creator, project lead.
- **Bala Raman + Nataraj Batchu** — joined some debug calls.

---

## Notes / gotchas

1. `nicctl reset card` HANGS THE HOST on this build. Confirmed on both nodes today. Use BMC AC cycle only.
2. After AC cycle, sometimes the bringup script's IP setup partially fails — run `set_ip_f02-X.sh` manually to fix.
3. NIC3 enumeration is flaky post-AC-cycle. Doesn't affect our NIC1 testing.
4. The dirty FW (`1.130.0-a-6-dirty`) is on NIC1 of BOTH nodes — preserved across AC cycles (FW is on flash). Other NICs are stock `1.130.0-a-6`.
5. `eth_dbgtool` and `capview` only work properly on f02-2 (Vijay's instrumented build patched their PAL discovery there). On f02-1 they fail with "no AMD NIC cards detected".
6. Vijay's `axi_filters.txt` workaround is at `/tmp/axi_filters.txt` on f02-2 — survives across reboots IF tmpfs persists (likely doesn't survive AC cycle since /tmp is usually wiped).
7. To run RCCL from f02-2 (if f02-1 SSH is denied), mpirun needs SSH from root@f02-2 → root@f02-1. This was broken several times today — root SSH trust isn't reliably set up.
8. Hugepages = 0 on both nodes. Not a blocker (IB and RCCL work without them) but per ROCm/PTE-walk skill, allocating hugepages may improve performance.

---

## Recommended next steps

1. **For NIC team:** Investigate `eth_rdma_os_impl_asicpd_p4plus_invalidate_cache` for the TO-KTE invalidation gap. Also map PC `0x010b9228` to source in the dirty build (likely `_sqcb_stage_wqe_read` in `meta_roce_tx_s0.p4`).
2. **For ROCm/HIP team:** Investigate the `hipStreamSynchronize` hang. Reproducible — every RCCL run after NIC fix hangs at the same stack. Try `modprobe amdgpu` without `ip_block_mask=0x4ff`.
3. **For setup team:** Stabilize SSH access (Conductor reservation, root key trust between f02-1 ↔ f02-2). Fix NIC3 enumeration issue at PCIe slot 3.
4. **Long-term:** Add `nicctl reset card` regression test on this build — it should NOT hang the host. Once that's fixed, give us a lighter recovery path than BMC AC cycle.
