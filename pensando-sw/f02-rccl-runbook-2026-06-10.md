# F02 RCCL Run — Operational Runbook (2026-06-10)

**Purpose:** Self-contained guide to access the F02 Helios-P mini-rack and run RCCL. Written so a fresh Claude session can pick this up cold and operate.

**Maintainer:** Pradeep Thangaraju. **For:** teammate running RCCL from their own session.

---

## TL;DR Current State

- Both nodes UP and healthy (4× MI450 GPUs each, NICs active, IPs set, bringup done).
- Overnight the lab flashed a new no-log SBIOS + new amdgpu (gfx1250) driver on both nodes.
- **RCCL still hangs** at the same GPU-side point (collective kernel never produces data).
- **Root cause (per RCCL team):** RCCL builds after May 9 don't actually build gfx1250 targets → the collective kernel binary is missing/wrong for MI450, GPU never produces data, proxy spins forever at "Gate 1". A rebuilt RCCL with proper gfx1250 targets is needed. Escalation is open (Tony Vaidya → Gilbert Lee / Nilesh Negi).
- So: a run today will almost certainly still hang. Useful only to re-confirm once a rebuilt RCCL lands.

---

## Cluster & Addresses (IMPORTANT — f02-2 IP changed)

| Node | Hostname | MPI/mgmt IP (enp1s0f0np0) | NIC1 data-plane IP | NIC1 BDF |
|---|---|---|---|---|
| f02-1 | `ctheliosp-1b114-f02-1.amd.com` | `10.5.236.25` | `192.168.1.6` | `0001:01:00.0` |
| f02-2 | `ctheliosp-1b114-f02-2.amd.com` | **`10.5.236.106`** (was 10.5.236.52 — changed after SBIOS reflash) | `192.168.1.20` | `0001:01:00.0` |

- f02-1 BIOS: `WHPV6520_4G_1_NoLog`
- HCA used by RCCL: `roceP1p3s0f3` (NIC1 only)
- GPUs: gfx1250 / MI450, DID `0x75c1`, 4 per node, SPX mode

> **The stale `10.5.236.52` is hardcoded in Karthik's `prepare2N.sh`.** Use `prepare2N_pradeep.sh` (already fixed to `.106`) or update the host list yourself. f02-2's IP may shift again on reboot — re-check with `getent hosts ctheliosp-1b114-f02-2.amd.com`.

---

## Access

```bash
# Jump host
ssh gunar@srv20

# From srv20 to each node (Conductor key; works for guramasam):
ssh guramasam@ctheliosp-1b114-f02-1.amd.com
ssh guramasam@ctheliosp-1b114-f02-2.amd.com
# Alt for f02-2 if needed: sshpass -p amd123 ssh amd@ctheliosp-1b114-f02-2.amd.com
```

- BMCs: `bmc-ctheliosp-1b114-f02-{1,2}.amd.com`, user `root`, pw `0penBmc`.
  **Only reachable from the OTHER node** (cross-node). NEVER AC-cycle both nodes at once — you lose the only jump path. (This bit us on 2026-06-09; needed a lab ticket to recover.)

---

## How to Run RCCL

### Pre-flight (after any reboot — do this first)

```bash
# On EACH node, run the full bringup (driver must already be loaded):
sudo bash /apps/shared/ib_tests/bringup/bringup_crossnode_f02-1.sh   # on f02-1
sudo bash /apps/shared/ib_tests/bringup/bringup_crossnode_f02-2.sh   # on f02-2
# Expect: all NIC ports PORT_ACTIVE, all cross-node pings PASS, "4 GPUs visible".
# The MPS=512B WARN is pre-existing and non-blocking.

# Confirm GPU driver loaded (lab loads it with: sudo modprobe amdgpu gpu_recovery=0):
/opt/rocm/bin/rocm-smi | grep -E '^[0-9] '     # should list 4 GPUs

# Root SSH trust f02-1 <-> f02-2 is needed for mpirun. Verify:
sudo ssh -o BatchMode=yes root@10.5.236.106 hostname   # from f02-1, should print f02-2 hostname
# If it fails: cross-install /root/.ssh/id_ed25519.pub into the peer's /root/.ssh/authorized_keys,
# and ensure sshd has 'PermitRootLogin prohibit-password' (sometimes reset on reboot).
```

### 2-node run (the real test)

```bash
cd /apps/karthik/rccl-test_bkcrocm_BKC260413
# Use the IP-fixed copy (points at 10.5.236.106):
sudo bash ./prepare2N_pradeep.sh 2>&1 | tee /tmp/rccl_$(date +%H%M%S).log
# If f02-2's IP changed again, edit MPI_HOSTS in that file first.
```

### 1-node run (sidesteps cross-node, good for quick kernel-path check)

```bash
cd /apps/karthik/rccl-test_bkcrocm_BKC260413
sudo bash ./prepare1N.sh 2>&1 | tee /tmp/rccl_1n_$(date +%H%M%S).log
# Both ranks on f02-1 (MPI_HOSTS="10.5.236.25:2")
```

Test binary in both: `sendrecv_perf -b 1K -e 1K`, custom `librccl.so` LD_PRELOAD'd.

---

## What PASS vs FAIL looks like

- **PASS:** mpirun.log prints a `busBw` table with rows for each size. (Not expected today.)
- **FAIL (current known hang):** log fills with repeating
  ```
  sendProxy Gate1 check: connFifo.size=-1 recvTail=0 posted=1 transmitted=0 ...
  ```
  on both ranks, forever. CTS handshake succeeds (ENTER/PostFifo/Completion = 2 each) but `CTS poll check = 0` and `busBw = 0`. This = GPU collective kernel never produced data.

### Quick triage while hung

```bash
L=$(ls -t /tmp/rccl_*.log | head -1)
for k in "sendProxy ENTER" "CTS PostFifo" "CTS Completion" "CTS poll check" busBw; do
  printf "%-20s: %s\n" "$k" "$(grep -c "$k" $L)"; done
# Stuck signature: ENTER=2, PostFifo=2, Completion=2, poll check=0, busBw=0
```

---

## Gotchas (learned the hard way)

1. **GPU% is unreliable on the new driver** — `rocm-smi --showuse` reports 100% even when idle with no GPU process. Don't use it to judge kernel activity. Use `rocm-smi --showpids` to see if a process is actually attached.
2. **`modprobe amdgpu` is sticky to first-boot args.** You cannot switch between with/without `ip_block_mask=0x4ff` without a power cycle (re-modprobe with different args runs for minutes and yields 0 GPUs). The mask is irrelevant to the hang anyway (proven 2026-06-09).
3. **Never AC-cycle both nodes simultaneously** (BMC jump path is cross-node only).
4. **AC cycle procedure** (from the node that can reach the target BMC):
   ```bash
   sshpass -p 0penBmc ssh root@bmc-ctheliosp-1b114-f02-X.amd.com mfg-tool power-control -p 0 -a cycle -s standby
   # wait ~90s for BMC reboot, then poll until i2c byte 0x30 == 09:
   sshpass -p 0penBmc ssh root@bmc-... 'i2cdump -y -f 6 0x20' | grep ^30:
   # once 0x30 shows 09:
   sshpass -p 0penBmc ssh root@bmc-... mfg-tool power-control -p 0 -a on
   # host boots in ~3-4 min
   ```
5. **`nicctl reset card` HANGS the host** on this build — use BMC AC cycle only.
6. **bringup does NOT modprobe** — assumes driver already loaded.

---

## Key Paths

| What | Path (on f02-1, NFS-shared) |
|---|---|
| RCCL test dir | `/apps/karthik/rccl-test_bkcrocm_BKC260413/` |
| 2-node launcher (IP-fixed) | `…/prepare2N_pradeep.sh` |
| 1-node launcher | `…/prepare1N.sh` |
| RCCL lib (LD_PRELOAD'd) | `/apps/karthik/rccl/rocm-systems/projects/rccl/build/release/librccl.so` |
| Bringup scripts | `/apps/shared/ib_tests/bringup/bringup_crossnode_f02-{1,2}.sh` |
| IP-only reset | `/apps/shared/ib_tests/bringup/set_ip_f02-{1,2}.sh` |
| Debug artifacts (2026-06-09) | `/apps/karthik/rccl-debug-2026-06-09-pradeep/` |

---

## Findings Reference

Full experiment write-up (why we know it's the gfx1250 build gap, all 7 root causes eliminated):
- Slack canvas: `https://amd.enterprise.slack.com/docs/T06GMR1V5/F0B8WKNQ1KR`
- Channel: `#f02-rccl-run`

---

## Contacts

- **Karthikeyan Arumugam** — RCCL/IB testing, owns the test scripts
- **Amar Eshappa Setra / Madan Easwaramoorthy** — lab access, BMC ops, SBIOS/driver installs
- **Tony Vaidya** — escalation to RCCL/GPU team (Gilbert Lee / Nilesh Negi)
- **Pradeep Thangaraju** — this runbook
