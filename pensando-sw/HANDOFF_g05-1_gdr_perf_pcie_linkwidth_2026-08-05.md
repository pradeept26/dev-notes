# Handoff — g05-1 GDR ib_write_bw perf: PCIe link-width downgrade root-cause + fix

**Date:** 2026-08-05
**Node:** `ctheliosp-1b114-g05-1.mnb.dcgpu` (10.5.237.28) — Helios-P, Vulcano AINIC, FW `SOC-OS 1.130.2-a-12`
**Author:** Pradeep Thangaraju (prthangar) + Loganathan Nallusamy — with Claude
**Related:** Jira **AI-7298** (IPv4/IPv6 GDR lineage), **AI-7437** (new-serdes/linkdrop on Helios-P), **DCLABOPS-28529** (g05 lab wiring); Slack group **C094ULXP3SB** (perf tuning), group DM **C0BN1QHJMRU**
**Prior handoffs (context):** `/home/vsampath/memories/HANDOFF_ib_write_bw_gdr_20260729.md` (f02 q2/q16 study), `HANDOFF_phb_oqdepth_capview_f02-2_20260729.md`, `HANDOFF_helios_f02_rccl_ipv6_status_2026-07-28.md`

---

## Addendum 2026-08-06 — clean re-flash of all 4 cards to hydra 1.130.2-a-12 (quasar → hydra)

Node was running quasar; re-flashed all 4 cards + reinstalled host tools. **Setup verified ready at line rate.**

- **Flash:** `nicctl update firmware -i ainic_fw_vulcano.tar --all --reset` (no `-c` = all cards; no `--force` — `--force` is rejected for main FW, only valid for pentrust/bootloader1). 3/4 cards clean.
- **★ Gotcha — card dropped off after flash:** card **0003** returned "Failed to populate PCIe devices after reset" (FLASH_EXIT=255) and **vanished from PCIe** (bridge + device absent from `lspci`/`/sys`). The **FW was already written** before the reset failed — a **BMC AC cold cycle re-enumerated it and it came up on the new FW**. Do NOT re-flash the missing card (nicctl hangs probing an absent card); cold-cycle first, then verify.
- **Host tools:** `install.sh -y` (non-interactive; bare `install.sh` loops forever on y/n with EOF). First pass **skipped ionic-dkms** because its uninstall step runs `rmmod ib_peer_mem` which returns rc1 when the module is in use → installer aborts ionic. **Fix:** rerun `install.sh -y` **after boot while amdgpu is still blacklisted** (ib_peer_mem not held) → ionic installs clean. Result: ionic-dkms 26.06.28.001, pds 1.130.2.a.12, rdma_core, perftest all on -a-12.
- **Post-cold-cycle recovery (all volatile):** all 4 cards **Gen6 x16**; `sudo modprobe amdgpu`; fclk re-pinned 1500 (`/home/visampath/perf/gpu_volt_clkfreq_1500.bash`); netns b2b + QoS re-applied.
- **Mapping this boot (no reshuffle):** ionic_0=0001/GPU0, ionic_1=0002/GPU1, ionic_2=0003/GPU2, ionic_3=0004/GPU3 (NIC 000X:03:00.3, GPU 000X:04:00.0 — same segment).
- **GDR sanity (q16, 8M, --use_rocm):** Pair A (0001↔0003) **777.61**, Pair B (0002↔0004) **777.62** Gb/s — line rate, all 4 datapaths verified.
- **Build change:** `nicctl update pipeline rdma path --count 8` syntax no longer valid on -a-12 (prints generic usage). Path-count left at default for sanity; find the new subcommand before a path-count study.

---

## TL;DR

- **Tracked goal:** run the GDR `ib_write_bw` **q2-vs-q16 sender-concurrency** study on g05-1 (continuing f02's work).
- **What blocked us (all cleared):** (1) `amdgpu` blacklisted → loaded; (2) no ROCm perftest → built from bundle; (3) NICs are **back-to-back cabled** (not switched) → netns b2b setup; (4) GDR throughput bogusly low (**55 / 442 Gb/s**).
- **Root cause of the low BW:** **PCIe link-width downgrade** — card **0003 = Gen6 x1**, card **0004 = Gen6 x8** (both LnkCap x16). This capped the *receiver's write-DMA drain* → Q3 ingress-buffer overflow → SACK/RTO retx → CWND collapse. x1 ≈ 60 Gbps → the 55 cap; x8 ≈ 484 Gbps → the 442 cap. Exact match.
- **Fix:** **BMC AC cold power-cycle** (`mfg-tool power-control -p 0 -a cycle -s standby`) → all 4 cards re-trained to **Gen6 x16**.
- **Result:** GDR unidir q16 **55/442 → 728** (both pairs), bidir **1094**; q2/q16/q64 = **610/728/729** → the f02 sender-concurrency ramp is reproduced.
- **★ SECOND FIX (q16 728 → 777 = f02 parity): GPU fabric clock.** g05 GPUs default to **fclk = 1100 MHz** vs f02 **1500 MHz**. Low fclk → GPU drains posted writes into HBM slowly → **PCIe posted-data (PD) credit-return starvation on the receiver** (PD 3–45 of 8190) → 728. Pinning **fclk=1500** → PD credits recover (6628) → **q16 = 777.6**. *(This supersedes an earlier wrong conclusion that 728 was PCIe/protocol overhead — see "Ceiling correction".)*
- **★ NEXT ISSUE TO TRACK — q2 metastable wedge (~594G).** With fclk=1500, q16=777 but **q2 pins at ~594G indefinitely** (doesn't self-warm); cleared *probabilistically* by any register/MMIO access on either NIC. A real HW/FW datapath bug — see `~/memories/HANDOFF_g05-1_q2_lowbw_2026-08-05.md` (Vishwas/Vijay) and Open Items §5.

---

## Access / environment

| Item | Value |
|---|---|
| Host | `ctheliosp-1b114-g05-1.mnb.dcgpu` = 10.5.237.28 |
| SSH | `ssh prthangar@10.5.237.28` (Conductor key; passwordless sudo). Resolves under `.mnb.dcgpu` — works from laptop/WSL, **not** from some dev servers |
| BMC | 10.5.236.55, `root` / `0penBmc` (OpenBMC). Reachable **from the host** (not from build servers). IPMI-over-LAN (lanplus) **fails** — use SSH + `mfg-tool` |
| OS / kernel | CentOS Stream 9, kernel `6.16.1-0_fbk2_brcmrdma5` (Meta/fbk) |
| FW | `SOC-OS 1.130.2-a-12`; pipeline = **hydra / meta-roce** (CC profile has omega/RCN) |
| GPUs | 4× MI (gfx1250), **Gen5 x16**, SPX/NPS1; ROCm 7.15; `amdgpu` is **blacklisted** at boot (`modprobe.blacklist=amdgpu`) — must `sudo modprobe amdgpu` after every boot |

### Cards (UUIDs are stable across reboot)

| Card BDF | UUID | Serial |
|---|---|---|
| 0001:01:00.0 | `42424650-5132-3632-3030-314631000000` | FPQ262001F1 |
| 0002:01:00.0 | `42424650-5132-3632-3030-323639000000` | FPQ26200269 |
| 0003:01:00.0 | `42424650-5132-3631-3930-314345000000` | FPQ261901CE |
| 0004:01:00.0 | `42424650-5132-3631-3930-323539000000` | FPQ26190259 |

### Topology — NICs are BACK-TO-BACK cabled (no switch)

| Pair | link | domains | GPUs |
|---|---|---|---|
| **A** | enP1 ↔ enP3 | 0001 ↔ 0003 | GPU0 ↔ GPU2 |
| **B** | enP2 ↔ enP4 | 0002 ↔ 0004 | GPU1 ↔ GPU3 |

GPU↔NIC by PCIe domain: GPU0=`0001:04:00.0` (`--use_rocm=0`), GPU1=`0002:04:00.0` (=1), GPU2=`0003:05:00.0` (=2), GPU3=`0004:05:00.0` (=3).

### ⚠️ ionic↔netdev enumeration RESHUFFLES across reboot

The `ionic_N` RDMA-device name is **not stable**; the netdev names (enP1–4) and PCIe domains are. After the last reboot the map is:

| ionic | netdev | domain | GPU (use_rocm) | netns / IP (this session) |
|---|---|---|---|---|
| ionic_0 | enP1 | 0001 | 0 | na / 10.0.13.1 |
| ionic_1 | enP2 | 0002 | 1 | nc / 10.0.24.1 |
| ionic_2 | enP3 | 0003 | 2 | nb / 10.0.13.2 |
| ionic_3 | enP4 | 0004 | 3 | nd / 10.0.24.2 |

**Always re-derive after a reboot:**
```bash
for d in ionic_0 ionic_1 ionic_2 ionic_3; do echo -n "$d "; cat /sys/class/infiniband/$d/ports/1/gids/1; done
# GID ...ffff:0a00:0d01=10.0.13.1(enP1) 0d02=10.0.13.2(enP3) 1801=10.0.24.1(enP2) 1802=10.0.24.2(enP4)
```

---

## Root cause: PCIe link-width downgrade

`lspci -s <card> -vv | grep LnkSta` (all cards LnkCap = Gen6 x16):

| Card | before cold-cycle | after cold-cycle |
|---|---|---|
| 0001 | Gen6 **x16** | x16 |
| 0002 | Gen6 **x16** | x16 |
| **0003** | Gen6 **x1** (downgraded) | **x16** |
| **0004** | Gen6 **x8** (downgraded) | **x16** |

**Bandwidth math:** Gen6 x1 ≈ 60 Gbps → pair A **55**; Gen6 x8 ≈ 484 Gbps → pair B **442**. The downgraded card is the *receiver* in each unidir test; its PCIe width caps the **write-DMA to memory**, which is the drain.

### Evidence chain (how we localized it)
1. `nicctl show card statistics packet-buffer --pf-statistics` → **receiver Queue-3 `IBufDrop`** (28.5M) — ingress buffer overflow on the RDMA data queue (DSCP 32 → prio 3). Queue 2 (ACKs) clean. MAC/wire clean (0 FCS/pause).
2. `asicmon -W --card <recv>` → receiver **write-DMA = 442 Gbps for BOTH GDR (to GPU) and host-mem (to RAM)** — identical → rules out GPU-Gen5, RX-compute (asicmon `-P`: DRDY=100, MPUs idle), PCIe *speed* (Gen6).
3. `lspci LnkSta` → the **x1/x8 width** downgrade. x8 ≈ 484 Gbps ≈ the 442 drain.
4. Downstream symptoms (all consequences of the drain cap): sender **SACK/RTO retx** (`nicctl show rdma queue-pair path --status` → Ring2=sack, Ring1=rto PI/CI), **CWND collapse** (`sqcb1.qp_cwnd_whole` ≪ `qp_cwnd_max`), `spec_failure`/`ack_msn not advancing` anomalies.

---

## The fix — BMC AC cold power-cycle

A **warm** reboot may not re-train PCIe width; a full **AC cold cycle** does. Procedure (from the f02 handoffs), run from the host (BMC reachable there):
```bash
sudo dnf install -y sshpass    # host has no sshpass by default
sshpass -p 0penBmc ssh -o StrictHostKeyChecking=no root@10.5.236.55 \
    "mfg-tool power-control -p 0 -a cycle -s standby"    # AC cycle (full cold)
#   ...-a cycle   = DC cycle (less thorough)
```
Node returns in ~3–5 min (host pings first, SSH/Conductor-auth a bit later). `/tmp` is **disk-backed → survives reboot** (built perftest + bundle persist). amdgpu/netns/QoS do NOT persist — re-run setup.

Result: all 4 cards re-trained to **Gen6 x16**.

---

## Results

GDR = `--use_rocm`, 8 MB msg, tclass 128, path-count 8, over b2b (netns).

| Test | before (x1/x8) | after (x16) |
|---|---|---|
| Pair A unidir q16 (GDR) | 55 | **728.0** |
| Pair B unidir q16 (GDR) | 442 | **728.6** |
| Pair B q2 / q16 / q64 (GDR) | — | **610.6 / 728.4 / 729.5** |
| Pair B bidir q16 (GDR) | 847* | **1093.8** |
| Pair B unidir q16 (host-mem) | 442 | **752.2** |
| Pair B bidir q16 (host-mem) | — | 743.9 |

\* pre-fix bidir 847 was on pair B (x8) before we understood the downgrade.

**q2/q16 signature reproduced:** q2 (610) < q16 (728) ≈ q64 (729) — the f02 sender-concurrency ramp; saturates by q16.

### ★ Ceiling correction — q16 728 → 777 is the **GPU fabric clock**, NOT PCIe overhead
> My original analysis here concluded "728 = ~3% GDR/GPU-Gen5 penalty + ~6% RDMA protocol overhead." **That was WRONG.** Vijay + Loganathan (Slack C094ULXP3SB, 2026-08-06) root-caused the real gap:
- **Symptom:** `asicmon` on the receiver showed `WR_PENDING_MAX = 8.2K` + PB-NET XOFF ~35, **but the RX p4+ pipeline had no bottleneck** (CH0/CH1 both UDs ~0, no s7→s0 pushback) → the 8.2K pending was unexplained by the pipeline.
- **Mechanism:** it's **PCIe posted-data (PD) credit-return starvation on the receiver NIC**. `nicctl show pcie credit -p 1`: receiver PD = **3–45 of the 8190 pool** (depleted) while the sender PD is full. Writes *push* out of the NIC in <0.5 µs, but PD credits are held ~1.4 µs → the limiter is **downstream credit-RETURN latency, not the NIC write path**. 8.2K pending ≈ the whole PD pool outstanding.
- **Root cause = GPU fclk:** g05 GPUs default to **fclk = 1100 MHz** vs f02 **1500 MHz** (sclk same story; mclk/socclk identical). Lower fclk → lower Infinity-Fabric BW draining posted writes into HBM → longer PD credit-return → PD depletion → **728**.
- **Fix (confirmed):** pin **fclk=1500** → PD credits 3–45 → **6628**, wr_pend 50 → 6, **q16 GDR 728 → 777.6 (f02 parity)**. *"The wr_pend=50 cap was never HW — it was the credit-return BDP."*
  ```bash
  cd /home/visampath/perf && bash ./gpu_volt_clkfreq_1500.bash   # agt_internal; SMC 0x5DC=1500
  rocm-smi --showclocks | grep -iE 'fclk|sclk'                    # confirm ~1500
  ```
  **Volatile** — resets on reboot. Open Q: *why* g05 defaults to 1100 (DPM / perf-level policy difference vs f02); a persistent perf-level would be better than the manual poke.
- (For reference, the earlier balance numbers at fclk=1100: sender GPU-read 734, receiver GPU-write 729, wire 745, goodput 728; host-mem 752 unidir. GDR bidir 1094 ≫ host-mem bidir 744 — GPU HBM vs system-RAM bandwidth. These all improve at fclk=1500.)

### Residual (at fclk=1100 / 728 — mostly a symptom of the above)
- Receiver Q3 `IBufDrop` ~23–83K/s; sender SACK ~78K/s + RTO ~9K/s; CWND ~54–84.
- **RCN** cut drops ~3.6× but not BW; **no-drop/PFC on p3** generated **0 pause frames** and didn't help.
- These drops/retx are **part of** the low state but **not the clean root cause** — the PD-credit-return (fclk) is. At fclk=1500 the q16 path runs clean at 777.

---

## Experiments matrix

| Change | Effect on the 442 cap |
|---|---|
| RDMA path-count 1→8 | none |
| DSCP QoS (32→prio3, 48→prio2 rdma-ack) | none |
| omega 5→10 | none |
| RCN enable | none (post-fix: cuts drops, not BW) |
| no-drop/PFC on p3 | none; **0 pause frames generated** |
| **BMC AC cold cycle (PCIe re-train)** | **FIXED → x16 → 728** |

Ruled out: PCIe *speed* (Gen6 x16), MAC/wire drops (clean), RX-pipeline compute (DRDY=100, MPUs idle), GPU-Gen5 (host-mem same cap), tclass/PFC.

---

## Gotchas (important)

- **Killing perftest:** `pkill -f ib_write_bw` matches your own SSH command string → kills the shell. `pkill -x ib_write_bw` is safe for the process name **BUT kills BOTH pairs** — and **Pair A (0001/0003) may be in use by others.** For the shared setup, use a **scoped kill**: `for p in $(pgrep -x ib_write_bw); do c=$(tr '\0' ' ' </proc/$p/cmdline); case "$c" in *ionic_1*|*ionic_3*) sudo kill -9 $p;; esac; done`.
- **q2-wedge investigation gotchas:** the wedge-clear is **probabilistic** → single-trial tests give false negatives/specificity (repeat ≥3×). **Measure BW from `ib_write_bw` stdout (`stdbuf -oL`), NOT asicmon** — asicmon reads PCIe regs and can *itself* kick the wedge (confounds the control). Firmware updates / other users' `nicctl` on any card also perturb it → test only in a clean window.
- **Same-host b2b needs netns** — a same-host ping/OOB is locally delivered by the kernel (0.02 ms, no ARP) = false positive; put each NIC in its own netns to force traffic onto the wire.
- **ionic device names reshuffle across reboot** — re-map by GID (above) before every test session.
- **asicmon flags on this build:** `-W` = bwmon/PCIe read-write BW (the doc's "`-b`" is the BDF selector here), `-P` = P4/wire monitor (RESETS counters), `-s <sec>` = PPS, `--card <uuid>` / `--bdf <bdf>` for selection.
- **SACK/RTO retx counters** live in `nicctl show rdma queue-pair path --status` → `Ring1 (rto retransmit): PI/CI`, `Ring2 (sack retransmit): PI/CI`, plus `Retransmit state` (idle/cwnd_retry/rto_retransmit) and `RTO … us`. `nicctl show rdma statistics` only has control-plane counters (QP/CQ/MR create).
- **PF drops with reasons:** `nicctl show card statistics packet-buffer --pf-statistics -c <uuid>` → per-port/queue `IBufCount/IBufDrop/EBufCount`. Queue 3 = RDMA data (DSCP 32).
- **No sshpass on host** by default (`dnf install -y sshpass`); **BMC IPMI lanplus fails** — use SSH + `mfg-tool` (OpenBMC/BusyBox).
- amdgpu blacklisted → `sudo modprobe amdgpu` after every boot (works despite the cmdline blacklist).

---

## Current node state (as left)

- **PCIe: all 4 cards Gen6 x16** ✅ (re-verify after any power event — it can re-downgrade at cold start).
- **GPUs: Gen5 x16 (native max — expected)**; `amd-smi static -g N --bus` → `MAX_PCIE_SPEED 32 GT/s`, `PCIE_INTERFACE_VERSION Gen 5`, part `MI450X_GENERIC`. Not a downgrade.
- **GPU fclk:** was pinned to **1500** (for q16→777) via `/home/visampath/perf/gpu_volt_clkfreq_1500.bash` — **volatile, resets on reboot**; g05 default is 1100. Re-pin after reboot and confirm with `rocm-smi --showclocks | grep -iE 'fclk|sclk'`.
- amdgpu loaded (4 GPUs); hugepages = 4096; netns `na/nb/nc/nd` + IPs up.
- Per-card config: **path-count = 8**, **no-drop = off** (pfc bitmap 0x0), DSCP classification applied (32→p3, 48→p2). omega back to default 5 after reboot.
- **RCN state has been toggled across sessions** — I left it enabled on pair B; the later q2 session (Vishwas/Vijay) notes it **disabled** on pair B. **Re-verify and set the desired baseline** before a study run: `nicctl show pipeline rdma congestion-control profile -p 0 -c <uuid> | grep 'Rate control'`.
- ROCm perftest: `/tmp/drivers-linux/perftest/ib_write_bw`; bundle: `/tmp/ainic_bundle_1.130.2-a-12/`. Also on box: `/home/visampath/perf/` (clock scripts), `/tmp/pcie_tag_autotune_vs` (Vishwas's tuner, patched).

---

## Reproduction / key commands

### Build ROCm perftest (once; survives reboot in /tmp)
```bash
sudo dnf install -y pciutils-devel
cd /tmp && tar xf /tmp/ainic_bundle_1.130.2-a-12/host_sw_pkg/ionic_driver/src/drivers-linux.tar.xz
cd /tmp/drivers-linux/perftest && ./autogen.sh
CFLAGS="-std=gnu99" ./configure --prefix=/tmp/pt --enable-rocm --with-rocm=/opt/rocm --enable-rocm-dmabuf
make -j$(nproc)      # -> ./ib_write_bw with --use_rocm / --use_rocm_dmabuf
```

### Post-boot setup (amdgpu + netns b2b + QoS)
```bash
sudo modprobe amdgpu; sleep 5
for n in na nb nc nd; do sudo ip netns del $n 2>/dev/null; sudo ip netns add $n; done
sudo ip link set enP1p3s0f3 netns na; sudo ip link set enP3p3s0f3 netns nb
sudo ip link set enP2p3s0f3 netns nc; sudo ip link set enP4p3s0f3 netns nd
sudo ip netns exec na sh -c 'ip addr add 10.0.13.1/24 dev enP1p3s0f3; ip link set enP1p3s0f3 mtu 9000 up; ip link set lo up'
sudo ip netns exec nb sh -c 'ip addr add 10.0.13.2/24 dev enP3p3s0f3; ip link set enP3p3s0f3 mtu 9000 up; ip link set lo up'
sudo ip netns exec nc sh -c 'ip addr add 10.0.24.1/24 dev enP2p3s0f3; ip link set enP2p3s0f3 mtu 9000 up; ip link set lo up'
sudo ip netns exec nd sh -c 'ip addr add 10.0.24.2/24 dev enP4p3s0f3; ip link set enP4p3s0f3 mtu 9000 up; ip link set lo up'
for c in 0001:01:00.0 0002:01:00.0 0003:01:00.0 0004:01:00.0; do
  sudo nicctl update qos --classification-type dscp -b $c
  sudo nicctl update qos dscp-to-purpose  --dscp 48 --purpose rdma-ack -b $c
  sudo nicctl update qos dscp-to-priority --dscp 48 --priority 2 -b $c
  sudo nicctl update qos dscp-to-priority --dscp 32 --priority 3 -b $c
  sudo nicctl update pipeline rdma path -p 0 --count 8 -b $c
done
```

### GDR run (pair B, verify ionic map first!)
```bash
BIN=/tmp/drivers-linux/perftest/ib_write_bw
sudo pkill -9 -x ib_write_bw; sleep 1
sudo ip netns exec nd $BIN -d ionic_3 -i 1 -x 1 --use_rocm=3 -s 8388608 -D 15 -q 16 --tclass 128 -F --report_gbits -p 5003 &
sleep 4
sudo ip netns exec nc $BIN -d ionic_1 -i 1 -x 1 --use_rocm=1 -s 8388608 -D 15 -q 16 --tclass 128 -F --report_gbits --bind_source_ip 10.0.24.1 -p 5003 10.0.24.2
sudo pkill -9 -x ib_write_bw
# host-mem: replace --use_rocm=N with --use_hugepages (set nr_hugepages first). bidir: add -b to both. QP: -q <N>. Pair A: na/nb, ionic_0/ionic_2, use_rocm 0/2, 10.0.13.x, port 5004.
```

### Diagnostics
```bash
sudo lspci -s 0004:01:00.0 -vv | grep LnkSta                                  # PCIe width (check after reboot!)
sudo nicctl show card statistics packet-buffer --pf-statistics -c <uuid>      # IBufDrop per queue
sudo asicmon -W --card <uuid>                                                 # PCIe read/write BW
sudo asicmon -P --card <uuid>                                                 # wire BW + per-stage (resets counters)
sudo nicctl show rdma queue-pair path --status -c <uuid>                      # SACK/RTO retx rings, CWND retry, RTO
sudo nicctl show rdma queue-pair --raw -c <uuid> | grep qp_cwnd_whole         # CWND collapse signature
sudo nicctl show pipeline internal rdma anomalies                            # spec_failure / ack_msn / drops
```

---

## Open items / next steps

**★ THE LIVE ISSUE TO TRACK — q2 metastable datapath wedge (~594G).**
With fclk=1500, **q16/q8/q4 = 777 (line rate) but q2 pins at ~594G indefinitely** (does not self-warm). Full analysis in **`~/memories/HANDOFF_g05-1_q2_lowbw_2026-08-05.md`** (Vishwas/Vijay). Summary:
- Behaves like a **metastable wedge in the pair's datapath**; cleared **probabilistically** by *any* register/MMIO access on **either** NIC (even off-pair card 0001, even a firmware update on other cards) — 2 to >12 tries, sometimes none. NOT specific to any register/command/card.
- Ruled out: PCIe read-tag count, `host_max_rd_req_cnt`, RCN, GPU fclk, path-count, translation cache. Vishwas's `pcie_tag_autotune` is a **follower** (tags 152 vs 512 both reach 778), not a fix.
- Proximate symptom: sender PCIe GPU-read latency 2.5–5 µs (low) vs <2.5 µs (cleared); receiver PB drops in the low state. Where it lives / why register access clears it = **unresolved HW/FW** (owners: Helen Peng / Vishwas / Michael Galles / Vijay; Slack **C094YDK9XPW**).
- Next: confirm cold-start-only (does it re-wedge mid-run?); repro on f02 / with a switch (all g05 data is b2b).

**Other:**
1. **Make GPU fclk=1500 persistent** — currently a manual/volatile poke (`/home/visampath/perf/gpu_volt_clkfreq_1500.bash`), resets on reboot. Investigate the DPM/perf-level policy so g05 defaults to 1500 like f02 (open Q: why g05 defaults to 1100).
2. **PCIe-width downgrade (lab / AI-7437):** *why* the link trained to x1/x8 at cold start. Likely the known Helios-P serdes/linkdrop issue. **Check `lspci LnkSta` width after any power event**; a cold cycle recovers it; escalate to lab/HW if it recurs.
3. **Invention Disclosure** for the dynamic pending-read (PCIe tag) tuner is being filed (Michael Galles / Vishwas) — `sw-dev9:.../pcie_tag_invention_disclosure.html`.
4. **Node cleanup:** RCN state has been toggled during testing — set the desired baseline before a study run. GPUs are **Gen5 x16** (native max, confirmed via `amd-smi static -g N --bus` → `PCIE_INTERFACE_VERSION: Gen 5`, part `MI450X_GENERIC`) — expected, not a downgrade.
