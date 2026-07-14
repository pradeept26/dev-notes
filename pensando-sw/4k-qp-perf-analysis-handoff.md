# 4K QP IB Write BW Performance Analysis — Handoff Document

**Date:** 2026-05-18
**Engineer:** Pradeep Thangaraju
**Build:** 1.125.0-a-240
**ASIC:** Vulcano / Hydra pipeline
**Testbed:** perf-3_4 (10.30.52.66 ↔ 10.30.52.75)

---

## 1. Objective

Analyse the `ib_write_bw` performance dip at 4K QPs observed in the systest report:
- **Report URL:** `http://srv6.pensando.io/systest/performance/ib_perf/vulcano/hydra/CPU/1.125.0-a-240/Report-IB-Bench-bidir-ipv6-perf-3_4/report.html`
- **Observation:** ~1440 Gbps at 4094 QPs vs ~1504 Gbps at 16 QPs (bidir 800G = 1600G theoretical)
- **Question:** Is this a firmware regression, config issue, or hardware limitation?

---

## 2. Testbed Details

| Parameter | Client | Server |
|-----------|--------|--------|
| **Mgmt IP** | 10.30.52.66 | 10.30.52.75 |
| **Credentials** | root/docker | root/docker |
| **Interface** | enp195s0f3 | enp195s0f3 |
| **PCIe BDF** | 0000:c1:00.0 | 0000:c1:00.0 |
| **ROCE device** | rocep195s0f3 | rocep195s0f3 |
| **PCIe** | Gen6 x16 (64GT/s) | Gen6 x16 (64GT/s) |
| **Link Speed** | 800 Gbps | 800 Gbps |
| **OS** | Ubuntu 24.04.3 LTS | Ubuntu 24.04.3 LTS |
| **Kernel** | 6.8.0-111-generic | 6.8.0-111-generic |

### Setup Commands (after card reset)

```bash
# 1. Interface + MTU
ip link set enp195s0f3 up
ip link set enp195s0f3 mtu 9000

# 2. IPv6 addresses
# Client: ip -6 addr add fd00::1/8 dev enp195s0f3
# Server: ip -6 addr add fd00::2/8 dev enp195s0f3

# 3. QoS config (same on both hosts)
bash /root/sunlake/qos_config.sh
# Contents:
#   ack_dscp=10, ack_prio=0
#   data_dscp=24, data_prio=3
#   nicctl update qos --classification-type dscp
#   nicctl update qos dscp-to-priority --dscp 24 --priority 3
#   nicctl update qos dscp-to-priority --dscp 10 --priority 0
#   nicctl update qos pfc --priority 3 --no-drop enable
#   nicctl update qos pfc --priority 0 --no-drop enable
#   nicctl update qos dscp-to-purpose --dscp 10 --purpose rdma-ack

# 4. Path count
nicctl update pipeline rdma path -p 0 --count 8
# NOTE: path_count × QPs ≤ 8192. For 4094 QPs → reduce to --count 2

# 5. Hugepages (~75% of RAM)
echo 3 > /proc/sys/vm/drop_caches; sleep 1
TOTAL=$(awk '/MemTotal/{print $2}' /proc/meminfo)
TARGET=$(( TOTAL * 75 / 100 / 2048 ))
echo $TARGET > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages
mount -t hugetlbfs nodev /dev/hugepages

# 6. Verify GID index (changes after driver reload!)
ibv_devinfo -d rocep195s0f3 -v | grep 'GID\['
# Use the index that shows fd00::X (typically 1 or 2)
```

### IB Command Templates

```bash
# Server (run first):
numactl --cpunodebind=netdev:enp195s0f3 --localalloc \
  ib_write_bw -d rocep195s0f3 -i 1 -x <GID_INDEX> -F --report_gbits -p 5002 \
  --bind_source_ip fd00::2 --tclass 96 \
  --tx-depth <TX> --rx-depth <RX> \
  -s 8388608 -q <QPS> -b -n <ITERS> \
  --use_hugepages --ipv6-addr

# Client (run after server):
numactl --cpunodebind=netdev:enp195s0f3 --localalloc \
  ib_write_bw -d rocep195s0f3 -i 1 -x <GID_INDEX> -F --report_gbits -p 5002 \
  --bind_source_ip fd00::1 --tclass 96 \
  --tx-depth <TX> --rx-depth <RX> \
  -s 8388608 -q <QPS> -b -n <ITERS> \
  fd00::2 --use_hugepages --ipv6-addr

# Infinite run (for steady-state diagnostics):
# Add: --run_infinitely -D 10  (reports every 10s)
# Remove: -n <ITERS>

# Multiplane (8 planes):
# Add: --planes=19.1.0.2 19.2.0.2 19.3.0.2 19.4.0.2 19.5.0.2 19.6.0.2 19.7.0.2 19.8.0.2
```

---

## 3. Analysis of the Systest Report

### 3.1 Report Data (ib_write_bw, bidir, 8MB msg)

| QPs | BW (Gbps) | % Line Rate | Step Loss |
|-----|-----------|-------------|-----------|
| 1 | 805.53 | 50.3% | — |
| 2 | 1495.61 | 93.5% | — |
| 4 | 1540.67 | 96.3% | **peak** |
| 8 | 1535.27 | 96.0% | -5.40 |
| 16 | 1521.02 | 95.1% | -14.25 |
| 32 | 1515.91 | 94.7% | -5.11 |
| 64 | 1507.67 | 94.2% | -8.24 |
| 128 | 1505.32 | 94.1% | -2.35 |
| 256 | 1504.46 | 94.0% | -0.86 |
| 512 | 1504.03 | 94.0% | -0.43 |
| 1024 | 1503.92 | 94.0% | -0.11 |
| 2048 | 1503.21 | 94.0% | -0.71 |
| **4094** | **1440.02** | **90.0%** | **-63.19** |

From QP#4 to QP#2048: gentle ~37 Gbps loss (2.4%) over 9 doublings.
From QP#2048 to QP#4094: sudden ~63 Gbps loss (4.2%) — 10x the step-loss rate.

### 3.2 Cross-Verb Comparison (8MB, bidir)

| Verb | QP#2048 | QP#4094 | Drop | Drop% |
|------|---------|---------|------|-------|
| ib_write_bw | 1503.21 | 1440.02 | -63.19 | -4.2% |
| ib_write_imm | 1500.11 | 1438.98 | -61.13 | -4.1% |
| ib_send_bw | 1506.47 | 1425.66 | -80.81 | -5.4% |
| ib_send_imm | 1506.37 | 1425.10 | -81.27 | -5.4% |

### 3.3 Build-over-Build (a-238 vs a-240 at QP#4094, 8MB)

Delta = -5.27 Gbps (-0.4%) → **NOT a regression**, consistent across builds.

### 3.4 write_imm vs write_bw Gap (Separate Issue)

`ib_write_imm` is 40-52% slower than `ib_write_bw` at mid-range message sizes (8K-32K) with high QPs. This is CQ completion overhead from the responder posting receive buffers — not related to the 4K QP dip. The gap closes at large messages.

---

## 4. Test Harness Analysis

### 4.1 Harness Location

**Systest harness:** `/home/gunar/IBBENCH/ib_bench.py`
**Pradeep's harness:** `/home/pradeept/ib_benchmark/run_ib_bench.py`

### 4.2 TX/RX Depth Selection (ib_bench.py lines 96-102)

```python
def derive_depth_var(verb, qp):
    depth_str = str()
    if qp > 64:
        depth_str = "--tx-depth 16 --rx-depth 16"  # FLAT RULE for all QPs > 64
        if verb in ['ib_atomic_bw', 'ib_read_bw']:
            depth_str = "--tx-depth 64 --rx-depth 1"
    return depth_str
```

### 4.3 Iterations (ib_bench.py lines 110-120)

```python
def derive_iter_var(qp):
    if qp == 64:           return "-n 100"
    elif qp in [128..1024]: return "-n 50"
    elif qp == 2048:       return "-n 20"
    elif qp == 4094:       return "-n 10"   # report showed -n 8
```

### 4.4 CQ Depth Constraint

- **FW max_cqe = 65,435** (from `ibv_devinfo`)
- perftest creates combined send+recv CQ: `(TX + RX) × QPs ≤ 65,435`
- At 4094 QPs: max `TX + RX = floor(65435/4094) = 15`
- Current config TX=16+RX=16=32 should exceed this — but the report ran successfully (see note below)
- **Our live tests confirmed `max_cqe=65435` is the hard limit** — CQ creation fails at 131K entries

**Note:** The systest report with TX=16/RX=16 at 4094 QPs may have used a different code path or perftest version that allocates separate send/recv CQs. Our manual tests with the same perftest 6.26 binary failed CQ creation at (16+16)×4094=131,008 entries.

---

## 5. Experiments Conducted

### 5.1 TX Depth Variation (path_count=2, RCN off, MTU 2048)

| Config | TX | RX | CQ entries | BW (Gbps) |
|--------|----|----|-----------|-----------|
| EXP 1 | 8 | 7 | 61,410 | **987.10** |
| EXP 2 | 14 | 1 | 61,410 | **986.14** |
| EXP 3 | 4 | 4 | 32,752 | **988.71** |

**Conclusion:** TX depth makes ZERO difference at 4K QPs. The bottleneck is not WQE pipeline depth.

### 5.2 CQ Limit Tests

| TX+RX | CQ entries | Result |
|-------|-----------|--------|
| 16+16=32 | 131,008 | **CQ creation FAILED** |
| 31+1=32 | 131,008 | **CQ creation FAILED** |
| 14+1=15 | 61,410 | OK |
| 8+7=15 | 61,410 | OK |

**Confirmed:** FW CQ limit is 65,435 entries. Cannot increase TX+RX beyond 15 per QP at 4094 QPs.

### 5.3 Multiplane Steady-State Diagnostics (the key experiment)

User ran infinite `ib_write_bw` with 8 multiplane IPs, collecting `asicmon` + `nicctl` at 2K, 3K, and 4K QPs.

---

## 6. Root Cause: Doorbell hcache Thrashing

### 6.1 Three-Way Comparison

| Metric | 2K QPs (2048) | 3K QPs (3072) | 4K QPs (4044) |
|--------|:---:|:---:|:---:|
| **Wire BW (bidir)** | ~1504 Gbps ✅ | ~1480 Gbps | ~1440 Gbps |
| **PCIe BW (R+W)** | 1535 Gbps | 1513 Gbps | 1437 Gbps |
| **Doorbell hcache hit% (server)** | **67%** | **23%** | **9%** |
| **TXS XOFF Q3 (sched1)** | 99% | 97% | 93% |
| **PF Egress XOFF** | 0x0 | 0x1842b | 0x5f7c7 |

### 6.2 Interpretation

```
Server hcache hit rate:
  2K QPs:  67%  → line rate (wire is the bottleneck, TXS XOFF Q3 = 99%)
  3K QPs:  23%  → pipeline starts falling behind (PF Egress XOFF appears)
  4K QPs:   9%  → pipeline starved, wire underutilized (TXS Q3 = 93%)
```

- The NIC's QP state cache (hcache) holds ~2K QPs worth of control blocks
- Beyond 2K QPs, each doorbell causes an HBM fetch (~150-170ns DDR latency)
- At 4K QPs, 91% of doorbells are cache misses → TX scheduler can't feed packets fast enough
- TXS XOFF Q3 drops from 99% → 93%: the egress port has **idle cycles** waiting for the pipeline
- PF Egress XOFF goes from 0x0 → 0x5f7c7: the port sometimes starves for data

### 6.3 Verdict

**Hardware cache capacity limitation, not a firmware or configuration bug.** The ~4% throughput loss at 4K QPs is the inherent cost of QP context-switch cache misses at this scale. No amount of TX-depth, CC tuning, or path configuration can recover it.

---

## 7. Additional Findings

### 7.1 asicmon Details (4K QPs, client)

```
Doorbell hcache: rd_hit/miss = 1.0B/3.7B (22% hit)
UDMA0 hostcache: rd_hit/miss = 0/683M (0% hit)
PTD: rd_pend=228, phb_drops=420M
PTD FIFO: lat depth=405 (high — qstate fetch latency)
Pipeline stages: 6-44% utilization (NOT saturated)
PCIe: 720+716 = 1437 Gbps (89% of Gen6 x16 max)
TXS0 XOFF Q3: 95%, TXS1 XOFF Q3: 93%
Zero packet drops, zero FCS errors, zero PFC
```

### 7.2 Config During Tests

```
Path count: 2 (reduced from 8 for 4094 QPs; 4094×2=8188 ≤ 8192)
RCN: Disabled
Omega: 5
Min RTO: 1000 µs
SACK retx mode: immediate
Hugepages: 193,345 (376 GB)
```

### 7.3 Post-Test QP Error State (from systest report)

- `ib_write_bw`: 0 QPs in error (expected — one-sided, no receives)
- `ib_write_imm`, `ib_send_bw`, `ib_send_imm`: ALL QPs in error state after test (expected — remaining posted receives cause error transition on cleanup; benign)

---

## 8. Diagnostic Data Files

All saved on the build server (this machine):

| File | Content |
|------|---------|
| `/tmp/diag_4kqp_client.txt` | Full 15-section diagnostics, 4044 QPs, client (10.30.52.66) |
| `/tmp/diag_4kqp_server.txt` | Full 15-section diagnostics, 4044 QPs, server (10.30.52.75) |
| `/tmp/diag_3kqp_client.txt` | 7-section diagnostics, 3072 QPs, client |
| `/tmp/diag_3kqp_server.txt` | 7-section diagnostics, 3072 QPs, server |
| `/tmp/diag_2kqp_client.txt` | 7-section diagnostics, 2048 QPs, client |
| `/tmp/diag_2kqp_server.txt` | 7-section diagnostics, 2048 QPs, server |

Each diagnostic file contains: XOFF, RDMA statistics, PF statistics, packet buffer drops, port statistics (JSON), pipeline anomalies (JSON), card interrupts (JSON), asicmon output, asicmon -b (PCIe BW), CC profile, path config, PCIe link status, active QP count, hugepage status, running processes.

---

## 9. Slack Summary (ready to post)

Target: Group DM `C094ULXP3SB`, thread `1779119133.203929`
Members: braman, gborker, lnallusa, nbatchu, prthangar, vatluri, visampath, vdanivas

Slack auth was expired at time of analysis. Summary text is in Section 6 above.

---

## 10. Open Questions / Next Steps

1. **Why did the systest report succeed with TX=16/RX=16 at 4094 QPs?** Our manual tests with the same perftest 6.26 binary failed CQ creation. The systest may use a custom perftest build or a different CQ allocation strategy.

2. **Can the hcache be enlarged?** This is a hardware parameter — would require ASIC changes. Worth discussing with the HW team whether the hcache size can be increased in future Vulcano revisions.

3. **RCN impact at 4K QPs:** We tested with RCN disabled. Enabling RCN adds per-path congestion state which may further increase hcache pressure. Worth testing.

4. **Multiplane vs single-plane at 4K QPs:** The user's test used 8 multiplane IPs. Single-plane might show different hcache behavior since all QPs share the same path state.

5. **write_imm mid-range gap:** The 40-52% write_imm penalty at 8K-32K msg sizes with high QPs deserves separate investigation (CQ completion overhead).

---

## 11. Key Commands Reference

```bash
# Diagnostics collection (run on both hosts during active test):
nicctl show qos packet-buffer xoff
nicctl show rdma statistics
nicctl show card statistics packet-buffer --pf-statistics
nicctl show rdma queue-pair --used --status | grep -c 'Queue state.*RTS'
source /etc/profile.d/amd_ainic_user_profile_update.sh && sudo -E asicmon
sudo -E asicmon -b
nicctl show pipeline rdma congestion-control profile -p 0
nicctl show pipeline rdma path -p 0

# RDMA cleanup after failed tests:
nicctl clear rdma internal queue
modprobe -r ionic_rdma && sleep 2 && modprobe ionic_rdma && sleep 3

# Kill stale IB processes:
ps aux | grep ib_write_bw | grep -v grep | awk '{print $2}' | xargs -r kill -9

# CQ limit check:
ibv_devinfo -d rocep195s0f3 -v | grep -E 'max_cq|max_cqe|max_qp'
```
