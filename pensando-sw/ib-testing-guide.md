# IB/RDMA Testing Guide for Hydra

## Quick Start - Simplified Commands

### Setup (One-time)
```bash
# Install Python dependencies (already done)
pip3 install paramiko openpyxl --user
```

### Using the Wrapper Script

Bash wrapper at `~/dev-notes/pensando-sw/scripts/run-ib-test.sh` provides SMC-specific presets and simplified options.
It calls the full-featured `~/run_ib_bench.py` with proper arguments for Excel generation and complex test orchestration.

### Basic Usage

```bash
# SMC1 → SMC2 with 4 QPs
~/dev-notes/pensando-sw/scripts/run-ib-test.sh smc1-smc2 --qp 4

# SMC1 → SMC2 with all QPs up to 16
~/dev-notes/pensando-sw/scripts/run-ib-test.sh smc1-smc2 --max-qp 16 --xlsx

# Bidirectional test
~/dev-notes/pensando-sw/scripts/run-ib-test.sh smc1-smc2 --qp 8 --direction bi

# Test both write modes
~/dev-notes/pensando-sw/scripts/run-ib-test.sh smc1-smc2 --qp 4 --write-mode both

# Custom QP count with TX/RX depth
~/dev-notes/pensando-sw/scripts/run-ib-test.sh smc1-smc2 --qp 4094 --tx-depth 16 --rx-depth 16 --iter 10

# Test specific interface (e.g., benic8p1)
~/dev-notes/pensando-sw/scripts/run-ib-test.sh smc1-smc2 --interface benic8p1 --qp 4094 --tx-depth 16 --rx-depth 16 --iter 10
```

### MSN Context Validation Tests (128-entry window)

```bash
# Heavy out-of-order test (validates new 128 MSN window)
~/dev-notes/pensando-sw/scripts/run-ib-test.sh smc1-smc2 --qp 1 --max-msg-size 1M --direction bi --iter 5000

# Multiple QPs stress test
~/dev-notes/pensando-sw/scripts/run-ib-test.sh smc1-smc2 --max-qp 16 --direction bi --write-mode both

# Single QP large messages
~/dev-notes/pensando-sw/scripts/run-ib-test.sh smc1-smc2 --qp 1 --max-msg-size 8M
```

### RCN (Congestion Control) Tests

```bash
# Test with RCN enabled
~/dev-notes/pensando-sw/scripts/run-ib-test.sh smc1-smc2 --qp 8 --rcn enable

# Test both RCN modes
~/dev-notes/pensando-sw/scripts/run-ib-test.sh smc1-smc2 --qp 4 --rcn both

# RCN with round-robin burst
~/dev-notes/pensando-sw/scripts/run-ib-test.sh smc1-smc2 --qp 8 --rcn enable --round-robin 8
```

---

## Original Script Usage (Advanced)

### Direct Usage of run_ib_bench.py

```bash
python3 ~/run_ib_bench.py \
    --server_ip 10.30.75.198 \
    --client_ip 10.30.75.204 \
    --username ubuntu \
    --password amd123 \
    --mode hydra \
    --qp_num 4 \
    --num_iter 1000 \
    --direction uni \
    --write_mode write \
    --generate_xlsx
```

### Key Parameters

**Connection:**
- `--server_ip`: Server IP address
- `--client_ip`: Client IP address
- `--server_intf`: Server interface name (e.g., benic1p1, benic8p1)
- `--client_intf`: Client interface name (e.g., benic1p1, benic8p1)
- `--username`: SSH username (default: root)
- `--password`: SSH password (default: docker)
- `--local_mode`: Run on same host (loopback)

**Test Configuration:**
- `--qp_num <N>`: Single QP count (supports any value, e.g., 1, 4, 4094)
- `--max_qp_num <N>`: Test powers of 2 up to N (e.g., 16 → tests 1,2,4,8,16)
- `--num_iter <N>`: Iterations per test (default: 1000)
- `--direction <uni|bi|both>`: Unidirectional, bidirectional, or both
- `--write_mode <write|write_with_imm|both>`: RDMA write variants
- `--tx_depth <N>`: TX depth (-t flag for ib_write_bw)
- `--rx_depth <N>`: RX depth (-r flag for ib_write_bw)
- `--repeat <N>`: Number of repetitions
- `--timeout <sec>`: Client idle timeout in seconds (default: 600)

**Hydra-Specific:**
- `--mode <hydra|mrc|rocev2>`: Platform mode (default: hydra)
- `--rcn <enable|disable|both>`: RCN congestion control
- `--round_robin_burst <1-15>`: Round-robin burst value
- `--skip_pipeline_clear`: Don't clear pipeline state before each test

**Message Size:**
- `--max_msg_size <size>`: Max size (supports 8K, 1M, 2G, etc.)

**Output:**
- `--generate_xlsx`: Generate Excel output with charts
- `--output_dir <path>`: Output directory (default: .)
- `--combined_bw_avg <path>`: Combined workbook path

---

## Test Scenarios for MSN Context Validation

### Scenario 1: Basic Sanity (Quick - 2 mins)
```bash
~/dev-notes/pensando-sw/scripts/run-ib-test.sh smc1-smc2 --qp 4 --iter 100
```
**Validates:** Basic RDMA write with 128 MSN window

### Scenario 2: Out-of-Order Stress (Moderate - 5 mins)
```bash
~/dev-notes/pensando-sw/scripts/run-ib-test.sh smc1-smc2 \
    --qp 1 \
    --max-msg-size 4M \
    --direction bi \
    --iter 2000
```
**Validates:** Heavy out-of-order packet arrival within 128 MSN window

### Scenario 3: Multi-QP Scaling (Comprehensive - 15 mins)
```bash
~/dev-notes/pensando-sw/scripts/run-ib-test.sh smc1-smc2 \
    --max-qp 16 \
    --direction both \
    --write-mode both \
    --xlsx
```
**Validates:** Multiple QPs with various traffic patterns, generates Excel report

### Scenario 4: RNR Threshold Test (Advanced)
```bash
~/dev-notes/pensando-sw/scripts/run-ib-test.sh smc1-smc2 \
    --qp 1 \
    --max-msg-size 8M \
    --direction bi \
    --iter 5000 \
    --rcn disable
```
**Validates:** Tests RNR behavior with new 128-entry limit

---

## Understanding Results

### Success Indicators
- ✅ Bandwidth > 0 Gb/sec
- ✅ No "Connection timed out" errors
- ✅ No excessive RNR NAKs in counters
- ✅ Smooth throughput across all QP counts

### Warning Signs with 128 MSN Window
- ⚠️ Lower bandwidth than baseline (256-entry window)
- ⚠️ Increased RNR NAK counters (check with `nicctl show stats`)
- ⚠️ Timeout errors in high-latency scenarios
- ⚠️ Performance degradation with bidirectional traffic

### Monitoring RNR Rate
```bash
# On server/client hosts
sudo nicctl show stats -j | grep -i rnr

# Watch for these counters:
# - rnr_nak_sent
# - rnr_nak_rcvd
# - rnr_retry_count
```

---

## Hardware Setups

### SMC1
- IP: 10.30.75.198
- Cards: 8 Vulcano NICs (ai0-ai7)
- Interfaces: benic1p1 - benic8p1

### SMC2
- IP: 10.30.75.204
- Cards: 8 Vulcano NICs (ai0-ai7)
- Interfaces: benic1p1 - benic8p1

### Network Topology
- Direct connection or via Micas switch (10.30.75.77)
- 400G/800G capable links

---

## Integration with CLAUDE.md

Add these shortcuts to your workflow:

**"run ib test"** or **"test ib basic"**
```bash
~/dev-notes/pensando-sw/scripts/run-ib-test.sh smc1-smc2 --qp 4
```

**"run ib stress"** or **"test msn window"**
```bash
~/dev-notes/pensando-sw/scripts/run-ib-test.sh smc1-smc2 --qp 1 --max-msg-size 4M --direction bi --iter 2000
```

**"run ib full"** or **"test ib comprehensive"**
```bash
~/dev-notes/pensando-sw/scripts/run-ib-test.sh smc1-smc2 --max-qp 16 --direction both --write-mode both --xlsx
```

**"test high qp count"** - Test with custom TX/RX depth
```bash
~/dev-notes/pensando-sw/scripts/run-ib-test.sh smc1-smc2 --qp 4094 --tx-depth 16 --rx-depth 16 --iter 10
```

**"test specific interface"** - Test using benic8p1 interface
```bash
~/dev-notes/pensando-sw/scripts/run-ib-test.sh smc1-smc2 --interface benic8p1 --qp 4094 --tx-depth 16 --rx-depth 16 --iter 10
```

---

## Troubleshooting

### Issue: "No module named 'paramiko'"
```bash
pip3 install paramiko openpyxl
```

### Issue: Connection timeout
- Check if hosts are reachable: `ping <IP>`
- Verify SSH: `ssh ubuntu@<IP>`
- Check if cards are up: `sudo nicctl show card`

### Issue: ib_write_bw not found
- Ensure perftest package installed on both hosts:
  ```bash
  sudo apt install perftest
  ```

### Issue: No RoCE interface found
- Check interface status: `ip link show`
- Verify RDMA device: `ibv_devices`
- Check GID index: `show_gids`

---

## Performance Baseline Expectations

### With 256 MSN Window (Original)
- 1 QP: ~50-100 Gb/sec
- 8 QPs: ~400-600 Gb/sec
- 16 QPs: ~700-800 Gb/sec

### With 128 MSN Window (After Change)
- Expected: Similar performance for most workloads
- Watch for: Increased RNR in high out-of-order scenarios
- Monitor: Bidirectional tests more sensitive to window size

---

## Claude Code Integration

When you say to Claude:
- **"run ib test"** → Executes basic 4 QP test between SMC1-SMC2
- **"test msn window"** → Runs stress test to validate 128-entry window
- **"ib benchmark"** → Full comprehensive test with Excel output

Claude will execute the appropriate wrapper script command automatically.
