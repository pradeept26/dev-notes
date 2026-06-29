# F02 RCCL Debug — Experiments Summary 2026-06-09

**Author:** Pradeep Thangaraju
**Cluster:** Helios-P F02 Meta Mini Rack (McNabb), 2× compute trays × 4× MI450 + 4× Pensando NICs
**Build:** RCCL custom librccl.so (Karthik) + ROCm 7.13-A0-26.05.04 + NIC FW 1.130.0-a-6-dirty

---

## Today's Goal

Continue debugging the RCCL hang that Karthik's instrumented run on 2026-06-09 already proved was **GPU-side, not NIC-side**:
- sendProxy stuck at Gate 1 (`connFifo.size=-1, recvTail=0, posted=1, transmitted=0`)
- GPU kernel never writes data
- NIC/CTS layer clean (status=0)

**Prime suspect coming in:** `modprobe amdgpu gpu_recovery=0 discovery=2 ip_block_mask=0x4ff` — specifically the `ip_block_mask=0x4ff` disabling GPU IP blocks needed for kernel dispatch/interrupt delivery.

---

## Experiments

### Experiment 1 — Modprobe WITHOUT ip_block_mask, fresh cold boot

**Hypothesis:** The mask was disabling something the RCCL kernel needed.

**Setup:**
- Full AC cycle of both nodes (had to be done carefully — first attempt did them in parallel which broke the cross-node BMC jump path, lab assist recovered)
- After fresh boot: first-ever `modprobe amdgpu gpu_recovery=0 discovery=2` (no mask)

**Result:**
- ✅ All 4 MI450 GPUs enumerated cleanly on both nodes
- ✅ `rocm-smi` shows them healthy (SPX mode, ~960W, 45°C, 256 CUs)
- ❌ **RCCL still hangs at the exact same Gate 1 point**
- Identical signature to Karthik's earlier instrumented run:

| Trace | Karthik's run | Today no-mask |
|---|---|---|
| `sendProxy ENTER` | 2 | 2 |
| `sendProxy Gate1 check` | 4536 spinning | 2195 spinning |
| `CTS PostFifo` | 2 | 2 |
| `CTS Completion` (status=0) | 2 | 2 |
| `CTS poll check` | 0 | 0 |
| `connFifo.size` | -1 | -1 |
| `recvTail, posted, transmitted` | 0, 1, 0 | 0, 1, 0 |

**Conclusion:** `ip_block_mask=0x4ff` is **not the cause** of the GPU hang. (And the mask is *required* for GPU enumeration on this BKC — yesterday's attempt to drop it after pre-loading with it gave 0 GPUs; only a first-modprobe on fresh boot lets you load without it.)

---

### Experiment 2 — Basic HIP sanity (does any GPU compute work?)

**Hypothesis:** Maybe the entire ROCm/HIP runtime is broken on this build.

**Setup:**
- Wrote a 33-line HIP vector-add: allocate device memory, launch kernel, hipDeviceSynchronize, verify
- Compiled with `/opt/rocm/bin/hipcc --offload-arch=gfx1250`
- Ran on f02-1 (with the no-mask driver still loaded)

**Result:**
```
GPU count: 4
hipDeviceSynchronize: no error
Result: PASS (c[0]=0 c[100]=300 c[1023]=3069)
EXIT=0
```

**Conclusion:** Basic ROCm/HIP works perfectly. The bug is **NOT** a generic ROCm-broken issue. It's specific to how RCCL's collective kernel dispatches.

---

### Experiment 3 — 1-node RCCL (eliminate network + multi-node)

**Hypothesis:** Maybe the hang is caused by some interaction between RCCL's two-node setup and the NIC/RDMA path.

**Setup:**
- Cloned `prepare2N.sh` → `prepare1N.sh`
- Changed `MPI_HOSTS="10.5.236.25:1,10.5.236.52:1"` → `MPI_HOSTS="10.5.236.25:2"`
- Same env, same binary, same custom librccl.so
- 2 ranks on f02-1 only (1 GPU each), NIC loopback

**Result:**
- ❌ **Same exact Gate 1 hang on the same single host**
- Same counters as 2-node case
- Both rank-0 (PID 53193) and rank-1 (PID 53194) processes on same GPU, both stuck

**Conclusion:** Multi-node / RDMA / cross-node interaction is **eliminated** as a cause. The hang reproduces with both ranks on a single host.

---

### Experiment 4 — Process-level inspection during hang

**Setup:** While RCCL was hung, ran:
- `rocm-smi --showpids` — what GPU is the process on?
- `rocm-smi --showuse` — is there GPU activity?
- `strace -c -p <PID>` — what syscalls is the process doing?

**Result:**
```
PID 44497 (sendrecv_perf)
  State: R (running, not blocked)
  VmRSS: 1.5 GB
  Threads: 12 (10 sleeping, 2 running)

  STRACE: 543,770 sched_yield in 3s = ~180K/sec (pure busy-spin)

  Threads running:
    Main thread       — busy spin (hipStreamSynchronize)
    Net proxy thread  — busy spin (Gate 1 wait)

  GPU usage: 0% on all 4 GPUs
  VRAM: 1.4 GB allocated on GPU 1
```

**Conclusion:**
- GPU process IS alive and has VRAM allocated → RCCL init worked
- GPU is 0% utilized → kernel never actually executes
- CPU is in busy-spin on a signal that never fires (HSA InterruptSignal::WaitAcquire per yesterday's gdb)
- Confirms Karthik's yesterday-handoff finding from a different angle

---

### Experiment 5 — AMD_LOG_LEVEL=4 to see the actual kernel dispatch

**Hypothesis:** The host-side wait is hanging on a completion signal — what is the kernel that's supposed to fire that signal?

**Setup:**
- Added `-x HIP_LAUNCH_BLOCKING=1` and `-x AMD_LOG_LEVEL=4` to mpirun env
- Re-ran prepare1N.sh

**Result — the smoking gun:**

The HIP/HSA log shows:
1. ✅ Many small init kernels (workgroup 512/1024, `private_seg_size=0, group_seg_size=0`) dispatch and complete fine
2. ❌ One specific kernel dispatched then hangs forever:
```
SWq=0x7f18202c2000, HWq=0x7ed7c3800000
Dispatch Header = 0xb00 (type=0, barrier=1, acquire=1, release=1)
workgroup=[256, 1, 1]
private_seg_size=1024    ← needs 1024B scratch per workitem
group_seg_size=45792     ← needs 45.7KB LDS per workgroup
kernel_obj=0x7f18202db640
completion_signal=0x0    ← fire-and-forget dispatch
```
3. Right after that dispatch:
```
Host wait on completion_signal=0x7f1823bfef80   ← waits on this signal
```
4. **That signal never fires.** Host wait never returns.
5. GPU usage stays at 0% — the kernel is enqueued but never executes.

**Conclusion:** The bug is specific to **this one RCCL collective kernel** with `private_seg_size=1024, group_seg_size=45792`. The HSA dispatch packet is enqueued correctly (queue's wptr increments), but the GPU never actually runs it. Small init kernels (private_seg=0, group_seg=0) on the same queue work fine.

---

### Experiment 6 — Remove HSA_NO_SCRATCH_RECLAIM

**Hypothesis:** The env had `HSA_NO_SCRATCH_RECLAIM=1` (suggests defensive workaround from earlier debugging). The big kernel's `private_seg_size=1024` is non-trivial scratch — if pre-allocated scratch is too small and the runtime can't reclaim/grow, the dispatch could silently fail.

**Setup:** Removed `HSA_NO_SCRATCH_RECLAIM=1` from prepare1N.sh env.

**Result:** ❌ Same Gate 1 hang.

**Conclusion:** Scratch reclaim is not the gate. Either scratch isn't the issue, or the runtime needs more aggressive scratch sizing flags.

---

### Experiment 7 — Control: re-run WITH mask (after AC cycle) for direct A/B comparison

**Goal:** Capture the same AMD_LOG_LEVEL=4 dispatch trace WITH the mask, so we can byte-compare the dispatch packets and prove the mask doesn't change anything at the kernel level.

**Setup:**
- AC cycled f02-1 only (controlled from f02-2's BMC reach)
- First-ever modprobe WITH `ip_block_mask=0x4ff` on fresh boot (took 22s, 4 GPUs healthy)
- Re-ran prepare1N.sh with `HIP_LAUNCH_BLOCKING=1` + `AMD_LOG_LEVEL=4`

**Result:**

| Variable | Without mask | With mask |
|---|---|---|
| GPUs enumerate | 4 | 4 |
| Big collective kernel size | `private_seg=1024, group_seg=45792` | **IDENTICAL** |
| Dispatch packet enqueued | ✓ wptr increments | ✓ wptr increments |
| Host wait on completion_signal | ✓ stuck forever | ✓ stuck forever |
| GPU usage | 0% | 0% |
| sendProxy visible (Gate1 spin) | Yes (async run) | No (HIP_LAUNCH_BLOCKING serialized main thread before it could post collective work) |

**Conclusion:** Mask is conclusively irrelevant. Both cases hang at the exact same point — completion_signal of the same kernel.

---

## What We've Eliminated as Root Causes

| Suspect | Status | How |
|---|---|---|
| NIC firmware / stale-PA bug | ❌ Eliminated | Karthik's instrumented traces yesterday — CTS completes status=0, no NIC anomalies |
| Multi-node / RDMA / cross-node | ❌ Eliminated | Experiment 3 (1-node reproduces same hang) |
| `ip_block_mask=0x4ff` driver param | ❌ Eliminated | Experiments 1 & 7 (A/B test with byte-identical dispatch packets) |
| BMC/host power state | ❌ Eliminated | Multiple AC cycles, fresh boots, reproduces deterministically |
| Basic ROCm/HIP runtime | ❌ Eliminated | Experiment 2 (vector-add works) |
| `HSA_NO_SCRATCH_RECLAIM=1` env | ❌ Eliminated | Experiment 6 (still hangs without it) |
| Karthik's custom librccl.so | ❌ Eliminated | Per Karthik: only adds debug prints, no logic changes |

## What Remains — for ROCm/HIP Team

Pinpointed to: **a specific RCCL collective kernel dispatch on gfx1250 that the GPU never executes**.

Key facts to give the ROCm team:
1. Kernel signature: `workgroup=[256,1,1], private_seg_size=1024, group_seg_size=45792`
2. HSA dispatch packet IS enqueued (queue wptr increments) — dispatch is accepted
3. Kernel never runs (rocm-smi reports 0% GPU usage throughout the hang)
4. Host waits on completion_signal forever (~180K sched_yield/sec)
5. Small init kernels (private_seg=0, group_seg=0) on the SAME queue work fine
6. Basic HIP vector-add works fine on the same GPU
7. ASIC: MI450 (gfx1250, DID 0x75c1, 256 CUs per GPU)
8. Stack: ROCm 7.13-A0-26.05.04, kernel 6.16.1-0_fbk2_brcmrdma5_35_g5ba27bd1d6b9, CentOS Stream 9
9. Reproduces deterministically — every run, single node sufficient

Open questions for ROCm:
- Why does the GPU silently drop a kernel dispatch despite the packet being enqueued?
- Is `private_seg_size=1024 + group_seg_size=45792` exceeding some pre-allocated limit?
- Any known issues with kernel dispatch on **gfx1250** with non-trivial private/group seg requirements in this BKC?
- Would `HSA_ENABLE_SCRATCH_SINGLE_LIMIT` or `HSA_ENABLE_DEBUG` provide more info?

---

## Procedural Findings (worth noting for handoff)

1. **`mfg-tool power-control -p 0 -a cycle -s standby`** truly leaves the host in standby — requires follow-up `-a on`. Never AC-cycle both nodes simultaneously (cross-node BMC jump path is the only way in).

2. **`modprobe amdgpu` is "sticky" to first-boot args**. Once loaded with the mask, you cannot load without it (or vice versa) without a power cycle. modprobe -r succeeds, re-modprobe with different args runs for several minutes and ends with 0 GPUs.

3. **AC cycle BMC procedure on F02:**
   - `mfg-tool power-control -p 0 -a cycle -s standby`
   - Wait ~90s for BMC reboot
   - Poll `i2cdump -y -f 6 0x20` byte 0x30 until it transitions to `0x09`
   - Then `mfg-tool power-control -p 0 -a on`
   - Wait ~3-4 min for host boot

4. **Per-boot reset items:**
   - `set_ip_f02-X.sh` to restore NIC IPs/routes
   - sshd `PermitRootLogin prohibit-password` (sometimes gets reset)
   - Cross-install root pubkeys f02-1 ↔ f02-2 for mpirun

5. **bringup_crossnode_f02-X.sh does NOT modprobe** — assumes driver is already loaded. Modprobe is a separate step that must be done first.

---

## Saved Artifacts

On f02-1 at `/apps/karthik/rccl-debug-2026-06-09-pradeep/`:
- `rccl_hiplog_073105.log` — AMD_LOG_LEVEL=4, no mask, 1-node (the smoking gun)
- `rccl_withmask_075942.log` — AMD_LOG_LEVEL=4, WITH mask, 1-node (control)
- `rccl_1n_072531.log` — clean 1-node run (no AMD_LOG)
- `rccl_noscratch_073733.log` — without HSA_NO_SCRATCH_RECLAIM
- `prepare1N_nomask.sh` — script for no-mask run
- `prepare1N_withmask.sh` — script for with-mask run

On `pradeept@sw-dev2`:
- `/home/pradeept/dev-notes/pensando-sw/f02-rccl-experiments-2026-06-09.md` — this file
- `/home/pradeept/dev-notes/pensando-sw/f02-rccl-handoff-2026-06-08.md` — yesterday's handoff
- `/home/karthik/logs/helios-rccl/f02-rccl-handoff-2026-06-09.md` — Karthik's morning handoff

---

## Cluster State at End of Today

- f02-1: UP, fresh boot post-AC-cycle, amdgpu loaded WITH mask, 4 GPUs healthy, NIC1 IP set, RCCL processes killed
- f02-2: UP, amdgpu loaded WITHOUT mask (from earlier today), 4 GPUs healthy, NIC1 IP set
- Cross-node ping working
- Root SSH trust restored both ways
- Ready for next session to continue debugging or run more experiments

---

## Follow-up: Re-test on new SBIOS + new gfx1250 driver (2026-06-10 / 06-11)

**Overnight lab work (Amar + Madan):** flashed a new no-log SBIOS (`WHPV6520_4G_1_NoLog`) and a **new amdgpu gfx1250 driver** on both nodes; loaded with `sudo modprobe amdgpu gpu_recovery=0` (no mask, no discovery — confirms mask not needed).

**Infra change:** f02-2's MPI/mgmt IP moved from `10.5.236.52` -> **`10.5.236.106`** after the SBIOS reflash. The old `.52` is stale in Karthik's `prepare2N.sh`; use `prepare2N_pradeep.sh` (IP-fixed copy) for 2-node runs.

**Result of 2-node RCCL on the new BIOS + new driver:** still hangs identically.
- MPI bootstrap, RCCL init, NIC, GPUs, cross-node — all healthy (infra fully validated)
- Collective still never completes: no busBw, GPU collective kernel never produces data
- 2026-06-11 re-confirm froze at the rccl-tests table header (quieter than the debug-build Gate1 spam, same fundamental hang)
- Note: new driver misreports `rocm-smi --showuse` as 100% even when idle — use `--showpids` instead

**Root cause confirmed (RCCL team, quoted by Amar 2026-06-10):**
> "all of the recent builds after May 9th don't actually build gfx1250 targets"

The RCCL collective kernel binary lacks proper gfx1250 (MI450) code, so the GPU never produces data and the proxy spins forever. A new amdgpu driver doesn't fix a missing kernel target. **Fix must come from RCCL/GPU team rebuilding with correct gfx1250 targets** — escalation open (Tony Vaidya -> Gilbert Lee / Nilesh Negi). Nothing further actionable from the cluster/NIC/driver side.

**Operational runbook for future runs:** `f02-rccl-runbook-2026-06-10.md` (also Slack canvas, shared with team).
