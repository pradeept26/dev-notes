# GT Vulcano 4x100G Multiplane — Debug Session Handoff
**Date:** 2026-08-20  
**Jira:** [AI-7677](https://pensando.atlassian.net/browse/AI-7677) — GT Vulcano Multiplane RCCL alltoall/alltoallv regression  
**Session participants:** Pradeep, Nataraj, Atul, Loganathan  
**Channel:** [#tmp-hydra-4x100g](https://xilinx.slack.com/archives/C0BGB9BQUBE)

---

## Testbed

| Node | IP | Card count | FW (end of session) |
|------|-----|-----------|---------------------|
| GT-1 (SC-GT-Node1) | 10.30.69.101 | 8× Vulcano | 1.130.2-a-11 |
| GT-4 (SC-GT-Node4) | 10.30.69.98  | 8× Vulcano | 1.130.2-a-11 |

| Switch | IP | Role |
|--------|-----|------|
| leaf1 | 10.30.69.196 | GT-1's leaf |
| leaf2 | 10.30.69.92  | GT-4's leaf |

**SSH credentials:**
- GT nodes: `root` / `docker`
- Switches: `admin` / `Micas123`

**RCCL benchmark dir:** `/home/amd/vul-rccl-benchmark/` (on GT-1)  
**Bundles available on GT-1:**
```
/home/amd/vul-rccl-benchmark/ainic_bundle_1.130.2-a-11/
/home/amd/vul-rccl-benchmark/ainic_bundle_1.130.5-a-7-2-ge0fb091dd78/
/home/amd/vul-rccl-benchmark/ainic_bundle_1.130.2-a-16/
```
GT-4 has: `ainic_bundle_1.130.2-a-11/` (others need to be SCP'd from GT-1)

---

## AI-7677 — Original Regression Report

Atul reported alltoall/alltoallv ~20-25% regression in **1.130.5-a-7** vs **1.130.2-a-11** baseline on GT 4x100G multiplane. All other collectives within ±0.5%.

| Collective | Baseline (2-a-11) | Regressed (5-a-7) | Delta |
|---|---|---|---|
| alltoall | 82.48 GB/s | 63.74 GB/s | **-22.7%** |
| alltoallv | 56.24 GB/s | 45.11 GB/s | **-19.8%** |
| all others | ~350 GB/s | ~351 GB/s | +0.2% |

---

## Key Discovery: 1.130.2-a vs 1.130.5-a Lane Mapping Difference

This is the most important finding of the session.

### MAC Channel Mapping

| Build | NIC port naming | MAC channels | Switch ports connected |
|-------|----------------|--------------|----------------------|
| 1.130.5-a | eth1/1/1,3,5,7 | 48, 16, **0, 32** (sequential) | Ethernet0,1,2,3 |
| 1.130.2-a | eth1/1/1,3,5,7 | 48, 16, **48, 16** (alternate) | Ethernet0,2,4,6 |

**1.130.5-a** uses consecutive internal MAC channels → all 4 NIC ports connect to 4 *consecutive* switch lanes (Ethernet0,1,2,3 within each OSFP group).

**1.130.2-a** uses alternating MAC channels → all 4 NIC ports connect to *every-other* switch lane (Ethernet0,2,4,6).

This means **moving between builds requires reconfiguring the switch** — different physical lanes are used.

### Detection
On 2-a firmware with 5-a switch config:
- NIC ports 5,7 stuck in `WAIT_PHY_LINK_UP` forever
- Switch lanes Ethernet4,6 are admin-disabled (5-a never used them)
- Switch lanes Ethernet1,3 are admin-enabled but oper-DOWN (nothing connected from 2-a side)

Nataraj's diagnosis: *"5-a uses sequential MAC channels and 2-a uses alternate MAC channels. It needs some port reset on switch side."*

Related Jira: **AI-5567** (4x100G WAIT_PHY_LINK_UP) — same symptom, resolved by enabling the correct switch lanes.

---

## Switch Reconfiguration (5-a → 2-a)

### Pre-requisite: Save 5-a backup
```bash
# On BOTH leaf1 and leaf2:
sudo config save /etc/sonic/config_db_5a_backup.json -y
```
Backup saved during session. ✅

### Per-OSFP group mapping change

For each of 8 OSFP groups (offsets 0,16,32,48,64,80,96,112):

| Old (5-a) | New (2-a) | Action |
|-----------|-----------|--------|
| EthN+0 = pip1 (keep) | EthN+0 = pip1 | No change |
| EthN+1 = pip2 | — | Shutdown, remove IP, unbind VRF |
| EthN+2 = pip3 → **now pip2** | EthN+2 = pip2 | Change IP + VRF to Plane2 |
| EthN+3 = pip4 | — | Shutdown, remove IP, unbind VRF |
| — | EthN+4 = pip3 | Startup, add IP, bind Plane3 |
| — | EthN+6 = pip4 | Startup, add IP, bind Plane4 |

### VRF assignments
```
Ethernet0,16,32,48,64,80,96,112    → Vrf_Meta_Plane1 (pip1, unchanged)
Ethernet2,18,34,50,66,82,98,114    → Vrf_Meta_Plane2 (pip2, was Plane3)
Ethernet4,20,36,52,68,84,100,116   → Vrf_Meta_Plane3 (pip3, new)
Ethernet6,22,38,54,70,86,102,118   → Vrf_Meta_Plane4 (pip4, new)
```

### Scripts used (saved in /tmp/ on the switches)
- `/tmp/reconfig_2a_leaf.sh` — IP reassignment
- `/tmp/fix_vrf_2a.sh` — VRF rebinding  
- `/tmp/readd_ips_2a.sh` — Re-add IPs after VRF rebind (VRF bind clears IPs)

### Verification
```bash
# After reconfiguration:
check_ipv6_connectivity.sh   # should show 40/40 passed
```

---

## Host-Side Fixes for 1.130.2-a-11

### 1. ionic_rdma driver missing on GT-1
After card reset, `ionic_rdma.ko` was not in the kernel module path on GT-1.

**Fix:**
```bash
# Copy from GT-4 (which has it) to GT-1
scp /lib/modules/6.16.1-0_fbk2_0_gf40efc324cc8/extra/ionic_rdma.ko \
    root@10.30.69.101:/lib/modules/6.16.1-0_fbk2_0_gf40efc324cc8/extra/
# Load it
insmod /lib/modules/$(uname -r)/extra/ionic_rdma.ko
depmod -a && modprobe ionic_rdma
```

**TODO:** Add to DKMS or `/etc/modules-load.d/ionic_rdma.conf` for persistence across reboots.

### 2. GID index changed
1.130.2-a-11 advertises the IPv6 VIP GID at index **2** (not index 1 as in 1.130.5-a-7).

GID layout on 2-a-11:
```
GID[0] = fe80::... (link-local)
GID[1] = 0000::ffff:25.1.0.0 (IPv4-mapped)
GID[2] = 2001::25:1:0:0 (IPv6 VIP) ← correct one
```

**Fix applied:**
```bash
# On both GT-1 and GT-4:
sed -i 's/NCCL_IB_GID_INDEX=1/NCCL_IB_GID_INDEX=2/' \
    /home/amd/vul-rccl-benchmark/run-rccl.sh
```

### 3. setup.sh must be run twice
After card reset, run `setup.sh` once, wait for interfaces to come up, then run again. First run brings up interfaces; second run properly sets IPv6 routes.

---

## RCCL Results Comparison

Run command: `./run-rccl.sh alltoall 1G 1G 3000`

| Build | busbw @ 1G | Notes |
|-------|-----------|-------|
| 1.130.5-a-7 | 56.86 GB/s | GID=1, 5-a switch config |
| **1.130.2-a-11** | **79.22 GB/s (+39%)** | GID=2, 2-a switch config, all 4 pips |

**Note:** The original AI-7677 regression (82→63 GB/s) was measured at *16G* message size and with the *incorrect switch config* (only 2 pips working in 5-a because 2-a lanes weren't enabled). A proper apples-to-apples comparison at 16G with correct switch config is still needed.

---

## QP/Path Qstate Analysis (from collected snapshots)

Snapshots saved on GT-1:
- 5-a-7 live snaps: `/tmp/snapshots_5a7/` (snaps 1-3 have live data, ~700K-990K lines each)
- 2-a-11 post-run: `/tmp/snapshots_2a11/snap_1_2a11_gt1.txt`

### Path Bitmap Distribution

| Pattern | 5-a-7 (live, snap3) | 2-a-11 (post-run) |
|---|---|---|
| 0/0/8/8 (all inactive) | 50% of QPs | 0% |
| **0/6-8/0-2/8 (mostly disabled)** | **34% of QPs** | **0%** |
| 4/0/4/8 (half active, none disabled) | 0% | 53% |
| 8/0/0/8 (all 8 active) | 0% | 31% |

5-a-7 shows 84% of QPs with **6-8 paths in DISABLED state** (window exhausted/retry-ring). 2-a-11 has zero disabled paths.

### CC Counters

| Counter | 5-a-7 avg/QP | 2-a-11 avg/QP |
|---|---|---|
| add_incr | 313,152 | 198,380 |
| mul_decr | 2,058 | 198,386 |
| **add:mul ratio** | **152:1** | **~1:1** |
| qwnd_max_limited | ~270 | N/A |
| num_tx_cnp | 0 | 0 |
| omega | **10** | **5** |

### RTT Bucket Distribution

| Bucket | 5-a-7 (QP14/Path0) | 2-a-11 (35 paths) |
|---|---|---|
| 0–25 µs | **51.9%** | 6.3% |
| 25–50 µs | 0.7% | **91.4%** ← healthy |
| 50–75 µs | 0.3% | 0.9% |
| **>75 µs** | **47.1%** | **1.3%** |
| Min RTT | 9 µs | 9 µs |
| Max RTT | 199 µs | 327 µs |

5-a-7 shows **bimodal RTT** (fast or slow, nothing in between) — consistent with lane quality issues or buffer bloat from aggressive CC (omega=10). 2-a-11 shows clean 91% concentration in 25-50 µs.

**Hypothesis (not yet confirmed):** The bimodal RTT in 5-a-7 may be caused by the sequential lane mapping using OSFP inner lanes (2,4 = Ethernet1,Ethernet3) which experience more cross-lane interference than the alternate lanes (1,3,5,7 = Ethernet0,2,4,6) used by 2-a-11. FEC corrections on inner lanes would produce the fast (<25µs no-correction) + slow (>75µs with correction) bimodal signature.

---

## CC Profile Difference

| Parameter | 5-a-7 | 2-a-11 |
|---|---|---|
| omega | **10** | **5** |
| epsilon | 1 | 1 |
| beta | 1 | 1 |
| qwnd_min | 2 | 2 |
| exact_cwnd_enforce | enabled | enabled |
| RCN | enabled | enabled |

omega=10 in 5-a-7 causes more aggressive CWND growth → contributes to path disabling. However, the lane change hypothesis may independently explain the bimodal RTT.

---

## Reverting to 1.130.5-a-7

```bash
# Step 1: Flash 5-a-7 firmware on both GT nodes (run in parallel)
BUNDLE=/home/amd/vul-rccl-benchmark/ainic_bundle_1.130.5-a-7-2-ge0fb091dd78
nicctl update firmware --image $BUNDLE/firmware/ainic_fw_vulcano.tar --all --reset
# Wait 2-3 min for cards to come back

# Step 2: Restore switch config on BOTH leaf1 and leaf2
sudo config reload /etc/sonic/config_db_5a_backup.json -y
# This restores Ethernet0,1,2,3 config and disables Ethernet4,6

# Step 3: Restore GID index on both GT nodes
sed -i 's/NCCL_IB_GID_INDEX=2/NCCL_IB_GID_INDEX=1/' \
    /home/amd/vul-rccl-benchmark/run-rccl.sh

# Step 4: Install 5-a-7 host tools (if needed)
cd $BUNDLE/host_sw_pkg && bash install.sh -y

# Step 5: Run setup on both nodes
cd /home/amd/vul-rccl-benchmark && bash setup.sh
bash check_ipv6_connectivity.sh   # expect 40/40
```

---

## Pending Items

1. **16G alltoall comparison** — Run `./run-rccl.sh alltoall 512M 16G 1000` on both builds with correct switch config (all 4 pips working, correct GID index) to reproduce/confirm/deny the original AI-7677 regression numbers.

2. **ionic_rdma.ko persistence on GT-1** — Currently loaded manually after each card reset. Should be added:
   ```bash
   echo 'ionic_rdma' >> /etc/modules-load.d/ionic_rdma.conf
   # Or add to DKMS via the host tools installer
   ```

3. **Lane cross-interference investigation** — Compare FEC correctable error counts on 5-a sequential lanes (Ethernet1,3 = inner OSFP lanes 2,4) vs 2-a alternate lanes (Ethernet4,6 = outer lanes 5,7). Ethernet1/3 are now admin-disabled on the switch — need to re-enable temporarily and check:
   ```bash
   # On leaf1:
   sudo config interface startup Ethernet1
   bcmcmd 'show c ce1' | grep -i fec
   ```

4. **RCCL run-rccl.sh GID index** — The GID index change (`NCCL_IB_GID_INDEX=2`) was applied in-place. If anyone resets the file or re-copies from a backup, it will revert to index 1 and RCCL will fail with "PIPs for GID not found". This should be documented in the benchmark README or made automatic.

5. **AI-7677 root cause** — Still open. The regression at 16G needs re-verification with proper setup. The CC analysis (omega=10 vs omega=5 + path disabling) and lane hypothesis are both worth investigating.

---

## Quick Reference

```bash
# Check all ports UP
nicctl show port 2>/dev/null | grep Operational | sort | uniq -c

# Check connectivity
cd /home/amd/vul-rccl-benchmark && bash check_ipv6_connectivity.sh

# Run RCCL alltoall (current 2-a setup, GID=2)
./run-rccl.sh alltoall 1G 1G 500

# Check CC profile
nicctl show rdma congestion-control profile -j -c <card-uuid>
nicctl show rdma path -j -c <card-uuid>

# Check anomalies
nicctl show pipeline internal rdma anomalies

# Clear pipeline state before a run
nicctl clear pipeline internal state --all
```
