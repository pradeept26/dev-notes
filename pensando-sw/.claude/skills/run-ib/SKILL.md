---
name: run-ib
description: Run IB bandwidth/latency perftests (write_bw, write_with_imm, read_bw, send_bw) on a dual-node Vulcano testbed (smc, waco, gt, kenya). Handles setup, execution, result parsing, single-NIC and multi-NIC parallel runs, QP sweeps, and omega comparisons. Use when user says run ib, ib write_bw, ib perftest, ib sweep, write_with_imm test, compare ib perf, ib bandwidth test.
---

# Run IB Perftest Skill

Run IB bandwidth/latency tests on a dual-node Vulcano testbed. Handles setup, execution, result parsing, and multi-NIC parallel runs.

> **Single-NIC loopback latency?** For NIC-pipeline latency on ONE card (no peer) — PCS/port loopback
> with macvlan namespaces + `ud_loopback=0` verification — use the **`/analyze-latency`** skill instead.

## Usage Examples

- "run ib write_bw on smc with 8 QPs"
- "run ib sweep on smc for qps 2,4,8,16,32,64"
- "run write_with_imm test on smc"
- "compare ib perf across omega 5,7,10 on smc"

## Inputs

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| testbed | yes | — | Testbed name — resolved from `~/systest-agentq/projects/ainic/meta-roce/testbeds/<name>.yaml` |
| verb | no | write_bw | `write_bw`, `write_with_imm`, `read_bw`, `send_bw` |
| qps | no | 8 | QP count(s): single value or list (e.g., "2,4,8,16,32,64") |
| sizes | no | -a (all) | `-a` for all sizes, or specific size (e.g., "65536", "8M") |
| bidirectional | no | true | Add `-b` flag |
| iterations | no | 5000 | `-n` value |
| omega | no | current | Omega value(s) to sweep (e.g., "5,7,10") |
| nics | no | benic1p1 | NIC device(s). Use 2 NICs on different NUMA nodes for parallel |
| parallel | no | false | Run 2 verbs on 2 NICs simultaneously |

## Reference Files

**Read these before executing — they contain the authoritative patterns:**

| File | Purpose |
|------|---------|
| `~/systest-agentq/projects/ainic/meta-roce/skills/run-multiplane-ib-test.md` | **Primary** — full Phase A/B/C execution pattern, TX/RX depth rules, skip rules, KI recovery |
| `~/systest-agentq/projects/ainic/platform/skills/run-rdma-test.md` | Generic dual-node pattern, namespace mode, post-test health check |
| `~/systest-agentq/projects/ainic/meta-roce/testbeds/<testbed>.yaml` | Testbed topology, IPs, credentials, NIC list, NUMA mapping |

## Test Modes

### Size modes

| Mode | Flags | Description |
|------|-------|-------------|
| All sizes sweep | `-a` | Sweep from 2B to 8M (2, 4, 8, ..., 8388608) |
| Single size | `-s <bytes>` | One specific size, e.g., `-s 65536` for 64K |
| Default | (neither) | Uses default 65536 (64K) |

### Duration modes

| Mode | Flags | Description | Timeout |
|------|-------|-------------|---------|
| Iteration | `-n <iters>` | Fixed number of exchanges (default 5000) | 7200s |
| Duration | `-D <seconds>` | Run for N seconds, report average | `N + 60s` |
| Infinite | `--run_infinitely -D <interval>` | Run forever, print results every `<interval>` seconds | None (kill to stop) |

**Examples:**
```bash
# Single size, 5000 iterations (most common)
ib_write_bw -s 65536 -n 5000 ...

# All sizes, 1000 iterations per size
ib_write_bw -a -n 1000 ...

# Single size, run for 30 seconds
ib_write_bw -s 65536 -D 30 ...

# Single size, run forever, report every 10 seconds (soak test)
ib_write_bw -s 65536 --run_infinitely -D 10 ...
```

**Note:** `-n` and `-D` are mutually exclusive. `-a` can combine with either.
For infinite mode, use `kill` or `Ctrl-C` to stop. Always clean up with `killall -9 ib_write_bw` on both hosts after.

## Pre-Test Setup

Run on BOTH hosts before any IB test. These are lost after reboot.

### 1. Hugepages

```bash
HP=$(ssh $HOST "awk '/HugePages_Total/{print \$2}' /proc/meminfo")
if [ "$HP" -lt 1024 ]; then
    TOTAL=$(ssh $HOST "awk '/MemTotal/{print \$2}' /proc/meminfo")
    TARGET=$(( TOTAL * 75 / 100 / 2048 ))
    ssh $HOST "echo 3 > /proc/sys/vm/drop_caches; sleep 1; echo $TARGET > /proc/sys/vm/nr_hugepages"
    ssh $HOST "mount | grep -q hugetlbfs || mount -t hugetlbfs nodev /dev/hugepages"
fi
```

### 2. Cross-subnet routes (if hosts on different subnets via switch)

```bash
# smc example: 30.1.x.x ↔ 30.2.x.x via switch gateway
ssh $HOST1 'for i in 1 2 3 4 5 6 7 8; do ip route add 30.2.${i}.0/24 via 30.1.${i}.2 dev benic${i}p1 2>/dev/null; done'
ssh $HOST2 'for i in 1 2 3 4 5 6 7 8; do ip route add 30.1.${i}.0/24 via 30.2.${i}.2 dev benic${i}p1 2>/dev/null; done'
```

### 3. Bringup (if after firmware update)

```bash
ssh $HOST "bash /mnt/clusterfs/bringup/vulcano_hydra_rccl_bringup.sh"
```

### 4. Kill stale processes

```bash
ssh $HOST 'killall -9 ib_write_bw ib_read_bw ib_send_bw 2>/dev/null'
sleep 3
```

## Scaled QP Testing

Running IB at high QP counts requires careful tuning of TX/RX depth, CQ limits,
path count, hugepage buffers, and perftest flags. Getting any of these wrong causes
hangs, allocation failures, or QP RTR errors.

### TX/RX Depth Rules

Select dynamically based on absolute QP count. Do NOT use fixed values.

```
abs_qps = qp × num_nics_in_test

if 2 ≤ abs_qps ≤ 127:    TX=128, RX=512
elif 128 ≤ abs_qps ≤ 511: TX=128, RX=383
elif 512 ≤ abs_qps ≤ 784:  TX=64,  RX=64
else (≥ 785):              TX=8,   RX=7
```

**Worked examples:**

| QPs | TX | RX | CQ cap applied? | Notes |
|-----|----|----|-----------------|-------|
| 2 | 128 | 512 | No | Standard, high throughput |
| 8 | 128 | 512 | No | |
| 64 | 128 | 512 | No | (128+512)×64 = 40,960 ≤ 65,435 |
| 128 | 128 | 383 | Yes | (128+383)×128 = 65,408 ≤ 65,435 |
| 512 | 64 | 64 | No | (64+64)×512 = 65,536 — borderline, add --noPeak |
| 2048 | 8 | 7 | Yes | (8+7)×2048 = 30,720 ≤ 65,435 |
| 4092 | 8 | 7 | Yes | (8+7)×4092 = 61,380 ≤ 65,435 |

### CQ Depth Cap (ALL verbs)

Perftest creates a combined send+recv CQ. If `(TX + RX) × QPs > 65,435`, CQ creation fails.
Apply after selecting the tier:

```
RX = min(RX, floor(65435 / qps) - TX)
```

### Read Verb Override

RDMA read responder does not post receive WRs — perftest exits with error if RX > 1:
```
if verb in [read_bw, read_lat]: RX = 1
```

### High QP Flags (≥ 512 QPs)

```
if qps >= 512:
    add --noPeak                              # prevents deadlock at high QPs
    ITERS = 2^ceil(log2(requested_iters))     # must be power-of-2 to avoid hangs
    # Examples: 5000 → 8192, 25000 → 32768
```

**KI-009:** Two-sided verbs (write_imm, send_bw) fail at 4092 QPs on default (1x800)
profile with `Failed to modify QP N to RTR` regardless of TX/RX depth. One-sided
write_bw works fine. Suspected firmware resource limit for receive-side QP state.

### Path Count Auto-Adjust

FW QP table limit: `qp × path_count ≤ 8192`. At high QPs, reduce path_count:

```bash
max_paths = floor(8192 / qp)
if current_paths > max_paths:
    nicctl update pipeline rdma path -p 0 --count $max_paths
# Examples:
#   64 QPs × 8 paths = 512 ≤ 8192   → keep 8
#   1024 QPs × 8 paths = 8192        → keep 8
#   4092 QPs × 8 paths = 32,736      → reduce to 2 (4092×2 = 8184)
```

### FW QP Limit

Per-card QP limit depends on firmware build:
```
build >= 181 → abs_qps_limit = 4096
build < 181  → abs_qps_limit = 1020

if qps_per_card > abs_qps_limit → SKIP test
```

### Hugepage Buffer Check

Perftest allocates `QPs × msg_size × 2` bytes as a single MR. With `-a` flag,
it allocates for the max size (8MB). Must fit in hugepage pool:

```bash
hp_total=$(ssh $HOST "awk '/HugePages_Total/{print \$2}' /proc/meminfo")
hp_avail=$(( hp_total * 2 * 1024 * 1024 ))   # bytes

# For -a flag: effective_size = 8388608 (8MB)
# For -s <size>: effective_size = <size>
required=$(( QPS * effective_size * 2 ))

if [ "$required" -gt "$hp_avail" ]; then
    echo "SKIP: buffer $(( required / 1073741824 ))GB > hugepages $(( hp_avail / 1073741824 ))GB"
fi
```

**Examples (assuming 24GB hugepages):**

| QPs | Size | Buffer = QPs × size × 2 | Fits? |
|-----|------|-------------------------|-------|
| 64 | 64K | 8 MB | Yes |
| 64 | -a (8M max) | 1 GB | Yes |
| 512 | -a (8M max) | 8 GB | Yes |
| 2048 | -a (8M max) | 32 GB | **No → SKIP** |
| 4092 | 64K | 512 MB | Yes |
| 4092 | -a (8M max) | 64 GB | **No → SKIP** |

## Verb to Binary Mapping

| Verb | Binary | Extra Flags |
|------|--------|-------------|
| write_bw | ib_write_bw | — |
| write_with_imm | ib_write_bw | --write_with_imm |
| send_bw | ib_send_bw | — |
| send_imm | ib_send_bw | --send_imm=0xffff |
| read_bw | ib_read_bw | — |
| write_lat | ib_write_lat | — |
| read_lat | ib_read_lat | — |

## Command Template

**Common args:**
```
--use_hugepages -i 1 --report_gbits -p $PORT -F -q $QPS -t $TX -r $RX -n $ITERS
```

Add as needed: `-a` (all sizes), `-b` (bidirectional), `-s $SIZE` (specific size), `--write_with_imm`, `--tclass 96`

**Server (HOST1 = smc1 = listener):**
```bash
ssh $HOST1 "timeout 7200 numactl --cpunodebind=netdev:$IFACE \
    $BINARY -d $DEVICE $COMMON_ARGS $VERB_FLAGS \
    > /tmp/ib_srv_${PORT}.log 2>&1" &
sleep 6
```

**Client (HOST2 = smc2 = connector, to HOST1 mgmt IP):**
```bash
ssh $HOST2 "timeout 7200 numactl --cpunodebind=netdev:$IFACE \
    $BINARY -d $DEVICE $COMMON_ARGS $VERB_FLAGS $HOST1_MGMT_IP \
    > /tmp/ib_cli_${PORT}.log 2>&1"
```

## NUMA-Aware Parallel Execution

For 2-NIC parallel runs, pick NICs on different NUMA nodes:

```bash
# Check NUMA mapping:
for i in 1 2 3 4 5 6 7 8; do
    echo "benic${i}p1: NUMA $(cat /sys/class/net/benic${i}p1/device/numa_node)"
done
# Typical: benic1-4 = NUMA0, benic5-8 = NUMA1
```

Use `numactl --cpunodebind=netdev:$IFACE` to pin each test to its NIC's NUMA node.

**Parallel pattern (2 NICs, different NUMA):**
```
NIC1: benic1p1 (NUMA0, port 18515) — verb A
NIC2: benic5p1 (NUMA1, port 18517) — verb B
```

Both servers start on HOST1, both clients run on HOST2. Results are independent.

## Omega Configuration

**Note:** Omega (ω) is a congestion control parameter specific to **Hydra / Meta RoCE** pipeline.
It controls the RTT inflation offset in the QWND calculation. Not applicable to Pulsar/RoCEv2.
For details on omega and other CC parameters, refer to the `/debug-meta-roce` skill and
`~/systest-agentq/projects/ainic/meta-roce/skills/run-multiplane-ib-test.md`.

Set before each test sweep:
```bash
# Set on BOTH hosts (root required):
ssh root@$HOST "nicctl update pipeline rdma congestion-control profile -p 0 --omega $OMEGA"

# Verify:
ssh root@$HOST "nicctl show pipeline rdma congestion-control profile -p 0 | grep -i omega"
```

Takes effect immediately, no QP reset needed.

## Result Parsing

Client output contains BW rows:
```
# size   iters   bw_peak   bw_avg   msg_rate
  65536   8000   715.25    711.32   1.356738
```

Parse with:
```bash
grep "^[ ]*[0-9]" $CLIENT_LOG | awk '{print $1, $3, $4, $5}'
```

**`ethernet_read_keys: Couldn't read remote address` at end of test is BENIGN** — ignore it.

## Cleanup Between Tests

```bash
ssh $HOST1 'killall -9 ib_write_bw 2>/dev/null' || true
ssh $HOST2 'killall -9 ib_write_bw 2>/dev/null' || true
sleep 3   # RDMA resource release
```

## Error Recovery (KI-007)

After SIGKILL of perftest with active QPs:
```bash
ssh $HOST "nicctl clear rdma internal queue"
sleep 2
# If GIDs lost:
ssh $HOST "modprobe -r ionic_rdma && sleep 2 && modprobe ionic_rdma"
sleep 5
```

## GPU Direct RDMA (GDR) — `--use_rocm`

The default system perftest (`/usr/bin/ib_write_bw`) does **NOT** support `--use_rocm`.
You must build perftest from the host_sw_pkg bundle with ROCm enabled.

**Use the bundle version matching the running firmware** to avoid compatibility issues.

### Build perftest with ROCm support

```bash
# 1. Extract drivers-linux from the bundle
cd /tmp
tar xf <bundle>/host_sw_pkg/ionic_driver/src/drivers-linux.tar.xz

# 2. Build perftest with ROCm enabled
cd /tmp/drivers-linux/perftest
./autogen.sh
CFLAGS="-std=gnu99" ./configure --prefix=/usr \
    --enable-rocm --with-rocm=/opt/rocm --enable-rocm-dmabuf
make -j$(nproc)
sudo make install

# 3. Verify
ib_write_bw --help | grep use_rocm
# Expected: --use_rocm=<rocm device id>  Use selected ROCm device for GPUDirect RDMA testing
#           --use_rocm_dmabuf            Use ROCm DMA-BUF for GPUDirect RDMA testing
```

**Prerequisites:**
- ROCm runtime installed at `/opt/rocm`
- `amdgpu` driver loaded (`modprobe amdgpu`)
- ACS disabled + 10-bit PCIe tags enabled (done by bringup script)
- Bundle version should match running firmware

### Running IB with GPU memory

```bash
# Allocate buffers in GPU memory (GPU index 0):
ib_write_bw -d roce_benic1p1 --use_rocm=0 -s 65536 -n 1000 --report_gbits -p 18515 -F -q 2 -b

# With DMA-BUF (alternative GPU memory path):
ib_write_bw -d roce_benic1p1 --use_rocm=0 --use_rocm_dmabuf -s 65536 -n 1000 --report_gbits -p 18515 -F -q 2 -b
```

### GPU-NIC Pairing (rocm_index to NIC mapping)

Each GPU and its paired NIC sit behind the same PCIe switch. The pairing is
determined by PCIe topology — GPU and NIC BDFs share the same upstream bridge.

**Quick discovery:**
```bash
# GPU BDFs:
rocm-smi --showbus

# NIC BDFs:
for nic in $(ls /sys/class/net/ | grep benic | sort); do
    bdf=$(readlink /sys/class/net/$nic/device | xargs basename)
    echo "$nic  $bdf"
done

# Full PCIe tree showing GPU-NIC pairs under same switch:
lspci -tv | grep -E "Pensando|AMD.*ATI"
```

**Pairing rule:** GPU and NIC on the same PCIe switch share a common bus range prefix.
Match by proximity in BDF space — the GPU bus number and NIC bus number are within
the same switch segment (e.g., GPU `05:00.0` pairs with NIC `08:00.3`, both under
the `[01-0a]` switch).

**Typical SMC mapping (8 GPU + 8 NIC):**

| rocm_index | GPU BDF | NIC | NIC BDF | NUMA |
|------------|---------|-----|---------|------|
| 0 | 05:00 | benic1p1 | 08:00 | 0 |
| 1 | 28:00 | benic2p1 | 25:00 | 0 |
| 2 | 48:00 | benic3p1 | 45:00 | 0 |
| 3 | 65:00 | benic4p1 | 68:00 | 0 |
| 4 | 85:00 | benic5p1 | 88:00 | 1 |
| 5 | A8:00 | benic6p1 | a5:00 | 1 |
| 6 | C8:00 | benic7p1 | c5:00 | 1 |
| 7 | E5:00 | benic8p1 | e8:00 | 1 |

**For GDR tests, always use the paired GPU-NIC for optimal PCIe path:**
```bash
# Example: test GDR on benic1p1 with its paired GPU[0]
ib_write_bw -d roce_benic1p1 --use_rocm=0 ...

# Example: test GDR on benic5p1 with its paired GPU[4]
ib_write_bw -d roce_benic5p1 --use_rocm=4 ...
```

**Note:** This mapping is host-specific. Always verify with `lspci -tv` or `rocm-smi --showbus`
on the actual host, as BDF assignments can vary across platforms.

### Alternative: grfwork tool

The `grfwork` tool is a dedicated GDR test tool with built-in `--use-rocm` support.
See `~/systest-agentq/projects/meta-test/test-cases/datapath/grfworks/` for test cases and
`~/systest-agentq/projects/meta-test/test-cases/datapath/grfworks/README.md` for parameter reference.

```bash
# Server:
grfwork --server --dev=roce_benic1p1 --gid=1 --port=20000 \
    --qp-num=2 --request=65536 --buf-size=65536 \
    --use-rocm --rocm-index=0 --duration=10 --print-thp

# Client:
grfwork --dev=roce_benic1p1 --gid=1 --port=20000 \
    --connect=<server_ip> --source-ip=<client_ip> \
    --qp-num=2 --request=65536 --buf-size=65536 \
    --use-rocm --rocm-index=0 --duration=10 --print-thp
```

## Example: Full Omega Sweep Script

See `/tmp/smc_ib_sweep.sh` for a complete working implementation that:
- Iterates omega values
- Runs 2 NICs in parallel (different NUMA nodes)
- Dynamically selects TX/RX depth
- Parses results to CSV
- Handles cleanup between tests
