# Handoff — g05-1 GDR perftest: Pair A assigned to Loganathan (4K-QP scale test)

**Date:** 2026-08-06
**For:** Loganathan Nallusamy (+ his Claude session)
**From:** Pradeep Thangaraju (prthangar)
**Node:** `ctheliosp-1b114-g05-1.mnb.dcgpu` (10.5.237.28) — Helios-P, 4× Vulcano AINIC + 4× MI GPU, FW **hydra 1.130.2-a-12**
**Related:** `HANDOFF_g05-1_gdr_perf_pcie_linkwidth_2026-08-05.md` (full perf/PCIe/fclk background), Slack groups **C094ULXP3SB**, **C094YDK9XPW**

---

## TL;DR

- The node is **shared**. **You (Loganathan) own PAIR A. Pradeep owns PAIR B.** Do **NOT** touch Pair B, and do **NOT** run any node-wide destructive command.
- Node is already set up and at line rate: FW 1.130.2-a-12, PCIe **Gen6 x16**, **fclk pinned 1900**, netns + QoS applied, ROCm perftest built. Nothing to install — just run on your pair.
- Your goal: **4096-QP (4K) scale** GDR `ib_write_bw`. ⚠ Heads-up from this session: **1024-QP *bidir* already failed with "Couldn't create CQ"** (CQ resource limit) — see §6 before you start.

---

## 1. Access (two-step login — verified 2026-08-06)

The target uses **key-based auth only** (Conductor SUT — password is rejected). It accepts **pradeept's** Conductor key. So you must **land on `pradeept@sw-dev2` first, then ssh to the target from there** (so the final hop uses pradeept's key). Both hops are key-based — **no passwords anywhere**.

```
hop 1:  loganan@sw-dev9  ->  pradeept@sw-dev2.pensando.io   (your pubkey is in pradeept's authorized_keys)
hop 2:  pradeept@sw-dev2 ->  prthangar@10.5.237.28          (pradeept's Conductor key, already on sw-dev2)
```

**Interactive:**
```bash
ssh -t pradeept@sw-dev2.pensando.io 'ssh prthangar@10.5.237.28'
```
or manually: `ssh pradeept@sw-dev2.pensando.io` then `ssh prthangar@10.5.237.28`.

**For your Claude (non-interactive, run a command on the target):**
```bash
ssh pradeept@sw-dev2.pensando.io 'ssh prthangar@10.5.237.28 "<your command>"'
```
Example (verified): `ssh pradeept@sw-dev2.pensando.io 'ssh prthangar@10.5.237.28 "hostname"'` → `ctheliosp-1b114-g05-1.mnb.dcgpu`.

> ⚠ **Do NOT use `ssh -J` / ProxyJump.** With `-J` the *final* hop authenticates with **your origin key** (loganan@sw-dev9), which is **not** authorized on the target → `Permission denied (publickey)`. The two-step form works because hop 2 runs *on* sw-dev2 and uses **pradeept's** key. Likewise `sshpass`/passwords do nothing here — auth is purely key-based. `sudo` on the target is passwordless.

---

## 2. ★ YOUR PAIR — Pair A (use ONLY these)

Same-host **back-to-back** cabled pair. Each NIC pairs with its own GPU on the same PCIe segment.

| Role | netns | ionic dev | NIC card BDF | Card UUID | GPU (`--use_rocm`) | IP |
|------|-------|-----------|--------------|-----------|--------------------|----|
| end 1 | `na` | `ionic_0` | `0001:01:00.0` | `42424650-5132-3632-3030-314631000000` | `0` | `10.0.13.1` |
| end 2 | `nb` | `ionic_2` | `0003:01:00.0` | `42424650-5132-3631-3930-314345000000` | `2` | `10.0.13.2` |

- **Subnet:** `10.0.13.0/24`   **TCP ports:** use **5004–5010** (Pradeep uses 5003).
- Data path is `nb` (server) ↔ `na` (client), or either direction.

## ⛔ NOT YOURS — Pair B (Pradeep). DO NOT TOUCH.

| netns | ionic dev | NIC card BDF | GPU | IP |
|-------|-----------|--------------|-----|----|
| `nc` | `ionic_1` | `0002:01:00.0` | `1` | `10.0.24.1` |
| `nd` | `ionic_3` | `0004:01:00.0` | `3` | `10.0.24.2` |

Never use: `ionic_1`, `ionic_3`, GPUs 1/3, netns `nc`/`nd`, subnet `10.0.24.x`, port `5003`, cards `0002`/`0004`.

---

## 3. ★★ INSTRUCTIONS FOR CLAUDE — isolation rules (read carefully)

You are sharing this node with another engineer running live traffic on Pair B. Violating these will disrupt his test.

1. **Only ever target `ionic_0`, `ionic_2`, netns `na`/`nb`, GPUs `0`/`2`, cards `0001`/`0003`, subnet `10.0.13.x`, ports `5004+`.**

2. **NEVER use a global `pkill`.** `sudo pkill -9 -x ib_write_bw` kills Pradeep's runs too. To stop *your* runs, kill **by your device name only**:
   ```bash
   sudo pkill -9 -f 'ib_write_bw.*ionic_0'
   sudo pkill -9 -f 'ib_write_bw.*ionic_2'
   ```
   (netns does **not** isolate PIDs, so `ip netns exec na pkill` is NOT safe either — always match by `ionic_0`/`ionic_2`.)

3. **Scope every `nicctl` to your cards** with `-b 0001:01:00.0,0003:01:00.0` (or `-c <your two UUIDs>`). Never run a bare node-wide `nicctl`.

4. **NEVER run node-wide destructive ops** (they hit both pairs / the whole box):
   - ❌ `nicctl update firmware`  ❌ reboot / `shutdown`  ❌ BMC power-control / cold-cycle
   - ❌ `nicctl clear pipeline internal state` on the node or on 0002/0004
   - ❌ changing hugepages/global sysctls without asking Pradeep

5. **`fclk` is GLOBAL** — the clock pin (currently 1900) applies to **all 4 GPUs**. Do **not** change it without coordinating with Pradeep. If you need it re-applied after a power event, that's a node-wide action → ask Pradeep.

6. If a command *must* be node-wide or you're unsure whether it's isolated, **stop and ask** rather than risk Pair B.

---

## 4. Current node state (already done — do not redo)

- **FW:** all 4 cards `SOC-OS 1.130.2-a-12`, `device_config/1.0.0` (default).
- **PCIe:** all 4 `Gen6 x16` (64 GT/s).
- **GPU:** amdgpu loaded; **fclk pinned ~1900 MHz** (volatile — resets on reboot).
- **QoS (per card):** dscp 32→prio 3 (data), dscp 48→prio 2 (ack).
- **netns:** `na`/`nb` (yours) and `nc`/`nd` (Pradeep's) up with IPs, MTU 9000.
- **hugepages:** `vm.nr_hugepages=4096` (8 GB) — shared; leave as is.
- **Baseline perf (q16, 8M, GDR):** unidir 777; **bidir 1521 @ fclk 1900** (was 1331 @ 1500). Both pairs run in parallel with zero contention (~3042 aggregate).

---

## 5. Paths

| Item | Path |
|------|------|
| ROCm perftest (`--use_rocm`) | `/tmp/drivers-linux/perftest/ib_write_bw` |
| FW/host-tools bundle | `/tmp/ainic_bundle_1.130.2-a-12/` |
| fclk scripts (global — coordinate) | `/home/visampath/perf/gpu_volt_clkfreq_{1500,1900}.sh` |

`/tmp` is disk-backed (survives reboot). netns/QoS/fclk/amdgpu do **not** survive reboot.

---

## 6. ★ 4K-QP goal — known constraints (learned this session)

Testing q=1024 today surfaced two hard limits you'll hit sooner at 4096 QP:

1. **CQ resource limit.** `-q 1024 -b` (bidir → 2048 QP/CQ) **failed**: `Couldn't create CQ / Failed to create CQs / Couldn't create IB resources` (the GPU buffer allocated fine; CQ creation is the wall). For 4K QP:
   - Start **unidir** (no `-b`) — half the CQ/QP count.
   - Expect to find the ceiling; if 4096 CQs still fail, reduce CQ depth (`-r`/`--rx-depth`, `-t`/`--tx-depth`) and/or QP count, and check `ibv_devinfo -d ionic_0` for `max_cq` / `max_qp`.

2. **GPU buffer sizing.** perftest allocates `buffer = size × qp × (2 if bidir)`. At `-s 8388608 -q 1024 -b` that was **16 GB**. At 4096 QP, 8 MB is far too large — for a **connection-scale** test use a **small message** (e.g. `-s 4096` or `-s 65536`). 4K QP × 64 KB ≈ 256 MB.

Suggested starting point (Pair A, unidir, 4K QP, small message):
```bash
BIN=/tmp/drivers-linux/perftest/ib_write_bw
# server (nb / ionic_2 / GPU2)
sudo ip netns exec nb $BIN -d ionic_2 -i 1 -x 1 --use_rocm=2 -s 65536 -n 1000 -q 4096 \
  --tclass 128 -F --report_gbits -p 5004 &
sleep 6   # 4K QP setup is slow
# client (na / ionic_0 / GPU0)
sudo ip netns exec na $BIN -d ionic_0 -i 1 -x 1 --use_rocm=0 -s 65536 -n 1000 -q 4096 \
  --tclass 128 -F --report_gbits --bind_source_ip 10.0.13.1 -p 5004 10.0.13.2
# stop (scoped!):
sudo pkill -9 -f 'ib_write_bw.*ionic_0'; sudo pkill -9 -f 'ib_write_bw.*ionic_2'
```
Tune `-q` down from 4096 if CQ creation fails; raise `-s` for a bandwidth read once QP setup is stable.

---

## 7. Ready-to-run reference (Pair A)

**GDR unidir q16 (sanity, expect ~777):**
```bash
BIN=/tmp/drivers-linux/perftest/ib_write_bw
sudo ip netns exec nb $BIN -d ionic_2 -i 1 -x 1 --use_rocm=2 -s 8388608 -D 15 -q 16 --tclass 128 -F --report_gbits -p 5004 &
sleep 4
sudo ip netns exec na $BIN -d ionic_0 -i 1 -x 1 --use_rocm=0 -s 8388608 -D 15 -q 16 --tclass 128 -F --report_gbits --bind_source_ip 10.0.13.1 -p 5004 10.0.13.2
sudo pkill -9 -f 'ib_write_bw.*ionic_0'; sudo pkill -9 -f 'ib_write_bw.*ionic_2'
```
**Bidir:** add `-b` to **both** sides (expect ~1521 @ fclk 1900).
**Diagnostics (scope to your cards):**
```bash
sudo nicctl show card statistics packet-buffer --pf-statistics -b 0001:01:00.0,0003:01:00.0
sudo PAL_CARD_UUID=42424650-5132-3631-3930-314345000000 asicmon -P   # 0003 wire/PCIe (WR_PEND_MAX, RLAT)
sudo lspci -s 0003:01:00.0 -vv | grep LnkSta                          # PCIe width
```

---

## 8. If something looks wrong

- **Don't reboot or cold-cycle** — it drops Pradeep's traffic and resets fclk/netns for both pairs. Ping Pradeep first.
- If your pair's link is down or a card misbehaves, capture `nicctl show ... -b <your bdf>` and coordinate; recovery (power events) is a node-wide action Pradeep owns.
- fclk drifting off 1900 or a card dropping to x1/x8 → tell Pradeep (both are node-level).

**Contacts:** Pradeep Thangaraju (prthangar) — node owner / Pair B. Perf background: Vishwas, Vijay (Slack C094YDK9XPW).
