# Handoff — g05-1 GDR perf (QP-scale), q256 QP-setup hang, and the driver/reset saga

**Date:** 2026-08-06
**Node:** `ctheliosp-1b114-g05-1.mnb.dcgpu` (10.5.237.28) — Helios-P, 4× Vulcano AINIC + 4× MI GPU, FW **hydra 1.130.2-a-12**
**Author:** Pradeep Thangaraju (prthangar), with Claude. Loganathan Nallusamy sharing the node (Pair A, 4K-QP).
**Related:** `HANDOFF_g05-1_gdr_perf_pcie_linkwidth_2026-08-05.md` (fclk/PCIe background), `HANDOFF_g05-1_loganathan_pairA_4KQP_2026-08-06.md` (pair split), Jira AI-7437 (Helios-P serdes linkdrop). Slack C094ULXP3SB, C094YDK9XPW.

---

## TL;DR (state as of this doc)

1. **Good perf results captured** (fclk=1900): bidir reaches ~2× unidir (line rate), full QP-scale + message-size matrices below.
2. **q256 (256 QPs) has a real client-side QP-setup HANG** — reproducible in isolation, all sizes, both dirs, **no CQ/RTR error**. q64 and q1024/q2048 are fine. Appeared **after Loganathan's ionic driver reinstall**.
3. **The "reset all cards → start fresh" attempt destabilized the box, then was recovered.** Went from "q16=777 works, only q256 hangs" → "even q16 hangs" (messy driver install + crash-reboot) → **RECOVERED** by a 2nd BMC AC cold-cycle + durable driver reinstall.
4. **RESOLVED (recovery):** after AC cold-cycle #2 — PCIe **x16** on all 4, drivers **auto-load durably**, nicctl sees 4 cards, **host-mem q16 = 753.95 Gb/s** (RDMA path healthy). Setup is back to a working baseline.
5. **★ q256 hang CONFIRMED REAL on the clean slate.** Re-tested q256 **host-mem** after the cold cycle → socket "Connected" but RDMA phase **hangs** (timeout, no BW). So q256 is a genuine **~256-QP datapath/QP-setup bug in ionic + FW 1.130.2-a-12** — NOT driver-state, NOT GDR-specific, NOT PCIe, NOT contention. q16 works, q1024/q2048 work; only ~256 hangs. **Escalate to driver/FW team.**

---

## Topology / identifiers (memorize these)

| Card BDF | Card UUID | ionic | netdev | GPU (`--use_rocm`) | netns / IP | Pair |
|----------|-----------|-------|--------|--------------------|-----------|------|
| 0001:01:00.0 | 42424650-5132-3632-3030-314631000000 | ionic_0 | enP1p3s0f3 | 0 | na / 10.0.13.1 | A (Loganathan) |
| 0002:01:00.0 | 42424650-5132-3632-3030-323639000000 | ionic_1 | enP2p3s0f3 | 1 | nc / 10.0.24.1 | **B (Pradeep)** |
| 0003:01:00.0 | 42424650-5132-3631-3930-314345000000 | ionic_2 | enP3p3s0f3 | 2 | nb / 10.0.13.2 | A (Loganathan) |
| 0004:01:00.0 | 42424650-5132-3631-3930-323539000000 | ionic_3 | enP4p3s0f3 | 3 | nd / 10.0.24.2 | **B (Pradeep)** |

- **ionic function BDF = 000X:03:00.3** (check PCIe width here, NOT the 01:00.0 bridge).
- ionic device names reshuffle after `nicctl reset`; a clean `modprobe` restores the canonical order above. **Always re-map** with:
  `for d in /sys/class/infiniband/ionic_*; do echo "$(basename $d) -> $(basename $(readlink -f $d/device)) -> $(ls $d/device/net)"; done`

### Access
- Claude runs on **sw-dev9 as pradeept** → reaches target directly by key: `ssh prthangar@10.5.237.28` (Conductor key; the `sshpass -p pensando` prefix is a no-op — auth is key-based).
- **BMC**: 10.5.236.55, `root`/`0penBmc`. Reachable **only from the host** (not from sw-dev*). AC cold cycle:
  `sshpass -p 0penBmc ssh root@10.5.236.55 "mfg-tool power-control -p 0 -a cycle -s standby"`
- Loganathan access (his pubkey is in pradeept's authorized_keys on sw-dev2): two-step, NOT `-J`:
  `ssh -t pradeept@sw-dev2.pensando.io 'ssh prthangar@10.5.237.28'` (see the pairA handoff for why -J fails).

### Key paths
- ROCm perftest (v6.26, `--use_rocm`): `/tmp/drivers-linux/perftest/ib_write_bw`
- Host-tools bundle: `/tmp/ainic_bundle_1.130.2-a-12/host_sw_pkg` (installer: `bash install.sh -y`)
- fclk scripts (global, volatile): `/home/visampath/perf/gpu_volt_clkfreq_{1500,1900}.sh` (SMC 0x5DC=1500, 0x76C=1900)
- Staged scripts on target: `/tmp/setup.sh` (netns+QoS), `/tmp/qp_scan.sh` (42-cell QP×size scan), `/tmp/q256.sh` (focused q256)
- `/tmp` is disk-backed → survives reboot. netns/QoS/fclk/amdgpu do NOT.

---

## Perf results (fclk=1900, Pair B GDR, q16 unless noted)

### fclk is the bidir lever (confirmed twice)
- fclk **1500→1900** (`gpu_volt_clkfreq_1900.sh`, 0x76C): q16 8M **bidir 1331→1521** (~98% of 2×777). Unidir unchanged (777). GDR bidir is **GPU-Infinity-Fabric-bound**; higher fclk lets each GPU sustain simultaneous read+write.
- Both pairs bidir **in parallel** = 1521 + 1520 ≈ **3042** aggregate, **zero contention at q16** (independent per-GPU/per-NIC).

### q16 message sweep (GDR, -n 10000)
| | 32K | 64K | 128K | 1M | 8M |
|--|----|----|----|----|----|
| uni | 574(32K→)  | **777** | 777 | 777 | 777 |
| — small-msg pps ceiling ~2.24 Mpps (uni), ~4.35 Mpps (bi); knee ~64K; line rate ≥64K. |

### QP-scale matrix — BW Gb/s (uni / bi), `-s` fixed, `/run-ib` depths
**Run 1 (before Loganathan's driver reinstall):**
| QP | 32K | 64K | 1M |
|----|-----|-----|-----|
| 2 | 509/922 | 539/939 | 576/1121 |
| 8 | 501/1030 | 625/1159 | 621/1201 |
| 16 | 499/1024 | 679/1186 | 774/1247 |
| 64 | 499/1031 | 676/1213 | 777/1400 |
| 256 | 541/FAIL | 693/FAIL | FAIL/FAIL |
| 1024 | 476/962 | **777/1511** | **777/1517** |
| 2048 | 454/903 | 776/1471 | 776/1380 |

**Takeaways:** q1024 = sweet spot (line rate 64K/1M). 32K never saturates + dips at high QP. Bidir ≈1.9–2.0× uni. **q256 fails** (see below).

### /run-ib QP-scaling rules used (abs_qps = qp, 1 NIC)
- TX/RX tiers: 2–127 →128/512; 128–511 →128/383; 512–784 →64/64; ≥785 →8/7.
- CQ cap (unidir): `RX=min(RX, floor(65435/qp)−TX)`. **Bidir doubles CQ** → use `TX+RX ≤ floor(65435/(qp×2))`.
- q≥512: add `--noPeak`, iters = power-of-2. Path count: `qp×path ≤ 8192` (path-count CLI **removed on -a-12** — only `queue-pair`/`sniff` subcommands exist).
- **Wrap perftest in `timeout -k 15 120`** — hung RDMA clients ignore SIGTERM; `-k` forces SIGKILL so a scan self-completes.
- **pkill gotcha:** inline `pkill -f "ib_write_bw.*ionic_1"` **self-matches the SSH command string** and kills the session. Use `[i]b_write_bw...` (self-exclusion) or put pkills inside a script file.

---

## ★ The q256 hang (primary open issue)

**Symptom:** at 256 QPs, GDR `ib_write_bw` **hangs during client-side QP setup** — client prints its config header, then stalls (never reaches local/remote address exchange). Server sets up its 256 QPs fine, receives the client's remote QPN, waits for data, times out at its `-D`/timeout. Client ignores SIGTERM.

**Characterized:**
- Reproducible **in isolation** (Pair A idle) at **all 3 sizes, both directions** → NOT contention.
- **No CQ error, no RTR error** at correct depths (uni 128/127 = 65,280; bi 64/63 = 65,024, both ≤ 65,435) → NOT a CQ-sizing problem.
- q64 works; **q1024 and q2048 work at line rate** → only ~256 QPs affected (non-monotonic → bug-like).
- **Timing:** q256 *unidir* worked at 32K/64K in Run 1 (541/693) **before** Loganathan's ionic reinstall; every q256 cell hangs **after** it.
- **★ CONFIRMED REAL on a clean slate (2026-08-06, post AC-cold-cycle #2):** with PCIe x16, freshly-installed drivers, and **host memory** (`--use_hugepages`, no GDR/amdgpu), q256 STILL hangs (socket Connected, RDMA phase times out with no BW), while q16 host-mem = 754. So the hang is **not** driver-state / GDR / PCIe / contention — it is a genuine ionic+FW ~256-QP issue.

**Reproducer (run on target; scrub separately, don't embed pkill):**
```bash
BIN=/tmp/drivers-linux/perftest/ib_write_bw
# scrub (separate shell/call): sudo pkill -9 -f "[i]b_write_bw.*ionic_1"; sudo pkill -9 -f "[i]b_write_bw.*ionic_3"
sudo ip netns exec nd $BIN -d ionic_3 -i 1 -x 1 --use_rocm=3 -s 65536 -n 2000 -q 256 -t 128 -r 127 --tclass 128 -F --report_gbits -p 5003 &   # server
sleep 5
sudo ip netns exec nc $BIN -d ionic_1 -i 1 -x 1 --use_rocm=1 -s 65536 -n 2000 -q 256 -t 128 -r 127 --tclass 128 -F --report_gbits --bind_source_ip 10.0.24.1 -p 5003 10.0.24.2   # client hangs
```
**Suspected root:** ionic driver / FW QP-creation issue (see `CREATE_QP BAD_ATTR` below), specific to a QP-count band around 256. Escalate to driver team / Loganathan.

---

## ★ Driver-stack findings (the reason "start fresh" was needed)

1. **`CREATE_QP (2) error BAD_ATTR (5)` / `Couldn't create ib_mad QP1` / `Couldn't open port 1`** on **all 4 cards at every driver load** (dmesg). Present since Loganathan's reinstall. Ports still show ACTIVE/LinkUp and RoCE data worked this morning (q16=777), so historically treated as the benign RoCE MAD-QP message — **but it may be the tail of the q256 QP-creation problem.** Worth confirming with the driver team.

2. **ionic driver was RAM-only after Loganathan's reinstall** — `dkms status` had ionic, but `/lib/modules/6.16.1-fbk2/` had **no ionic.ko** (only for old 5.14.el9 kernels) and `/usr/src` had no ionic source. So on the first cold-cycle reboot, ionic vanished (`modprobe: Module ionic not found`). **The running kernel is `6.16.1-0_fbk2_brcmrdma5_35` (a custom FB kernel)** — confirm the ionic build (26.06.28.001) is actually correct for it.

3. **install.sh fails when modules are in use.** ionic uninstall runs `rmmod ib_peer_mem` (held by amdgpu) → aborts; pds uninstall blocked by ionic. **Fix that worked:** fully quiesce first, then install:
   ```bash
   sudo rmmod amdgpu; sudo modprobe -r ionic_rdma ib_peer_mem ionic
   cd /tmp/ainic_bundle_1.130.2-a-12/host_sw_pkg && sudo bash install.sh -y   # → pds + ionic install DURABLY
   ```
   After this, drivers auto-load on boot and `nicctl show card` sees all 4.

4. **`modprobe amdgpu` crash-rebooted the host once** (uptime reset to 2 min immediately after). amdgpu had loaded fine earlier in the day, so possibly a one-off under heavy driver churn — but **treat amdgpu load as risky**; load it alone and verify the host stays up before proceeding.

---

## ★ Reset saga — what to do / NOT do

- **`nicctl reset card --all` is a WARM reset → downgraded PCIe on ALL cards to x1/x2/x8** (AI-7437 serdes). Confirmed via dmesg "available PCIe bandwidth, limited by ... x1/x2 link". **Do NOT rely on `nicctl reset card` for a clean start.**
- **Only a BMC AC cold-cycle recovers PCIe x16.** Verify per-card width at the **ionic function**:
  `for b in 0001 0002 0003 0004; do echo -n "$b: "; sudo lspci -s $b:03:00.3 -vvv | grep -oE "Width x[0-9]+"; done`
- A plain `systemctl reboot` is unproven for width and risks another downgrade → prefer AC cold-cycle.

---

## Post-boot recovery checklist (run after the AC cycle completes)

```bash
# 1. PCIe width (expect x16 on all 4; if x1/x2/x8 -> AC cold-cycle again)
for b in 0001 0002 0003 0004; do echo -n "$b: "; sudo lspci -s $b:03:00.3 -vvv | grep -oE "Width x[0-9]+"; done
# 2. drivers auto-loaded? nicctl sees cards?
lsmod | grep -E "ionic|pds|ib_peer"; sudo nicctl show card | grep -c vulcano   # expect 4
# 3. re-map ionic->bdf->netdev (canonical order after clean modprobe)
for d in /sys/class/infiniband/ionic_*; do echo "$(basename $d)->$(basename $(readlink -f $d/device))->$(ls $d/device/net)"; done
# 4. netns + QoS + hugepages
sudo bash /tmp/setup.sh; sudo sysctl -w vm.nr_hugepages=4096
# 5. HOST-MEM q16 sanity FIRST (no amdgpu -> avoids the crash). Server bg, client fg:
BIN=/tmp/drivers-linux/perftest/ib_write_bw
sudo ip netns exec nd $BIN -d ionic_3 -i1 -x1 --use_hugepages -s8388608 -D12 -q16 --tclass 128 -F --report_gbits -p 5003 &
sleep 6; sudo ip netns exec nc $BIN -d ionic_1 -i1 -x1 --use_hugepages -s8388608 -D12 -q16 --tclass 128 -F --report_gbits --bind_source_ip 10.0.24.1 -p 5003 10.0.24.2
#   -> if this returns ~750 Gb/s, RDMA path is healthy again. If it HANGS, the ionic/FW issue persists -> escalate.
# 6. only then: sudo modprobe amdgpu (verify host stays up), sudo bash /home/visampath/perf/gpu_volt_clkfreq_1900.sh, then GDR (--use_rocm=1/3).
```

**Server hang gotcha:** a healthy server prints "Waiting for client to connect..." within ~1s. If it stalls after only the `libibverbs ... bng_re ... libxdp.so.1` warning, RDMA init is hung (the current regression).

---

## Open items / escalation

1. **q256 client-side QP-setup hang** — primary. No CQ/RTR error; only ~256 QPs; appeared post-ionic-reinstall. Owner: driver team / Loganathan. Provide the reproducer above.
2. **ionic driver correctness for kernel `6.16.1-fbk2`** — reinstall was non-durable and `CREATE_QP BAD_ATTR` recurs. Confirm the right ionic package/version for this kernel.
3. **`modprobe amdgpu` crash-reboot** — reproduce carefully / flag to GPU team.
4. **AI-7437 PCIe serdes** — warm resets (incl `nicctl reset card`) downgrade width; only AC cold-cycle recovers x16. Check width after ANY power/reset event.
5. Node shared with Loganathan (Pair A). Keep all ops scoped to Pair B (ionic_1/ionic_3, cards 0002/0004, netns nc/nd, port 5003).
