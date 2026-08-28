# LLC Atomic Meter Rate Limiter — Validation Handoff

**Date:** 2026-08-28
**Author:** Pradeep Thangaraju
**Testbed:** kenya-perf-3 (10.30.52.66) ↔ kenya-perf-4 (10.30.52.75)
**Firmware:** `1.130.0-a-85-13-g21678fe1499-dirty` (Gaurav's `meter_rl_llc` branch)
**Device config:** 4×200G (`device_config_rdma_4x200G_2`)
**Patch applied:** `/home/pradeept/llc_rl_lif_init_fix.patch` (see LLC_RL_HOLB_HANDOFF.md)

---

## Test Setup

### Nodes
- **perf-3** (10.30.52.66): server/receiver — credentials: root/docker
- **perf-4** (10.30.52.75): client/sender — **RL must be enabled here** (TX pipeline)

### Key rule
RL operates on the **TX pipeline** (`pred.req_tx` path). Must be enabled on the **sender/client** node, not the receiver.

### ib_write_bw command (4×200G, 4 planes)
```bash
# Server (perf-3)
numactl --cpunodebind=netdev:enp195s0f3 ib_write_bw \
  -d rocep195s0f3 -m 4096 -s 1048576 --run_infinitely \
  -q <N> -x 1 --report_gbits \
  --planes=19.1.0.2,19.2.0.2,19.3.0.2,19.4.0.2 \
  -D 1 --tclass=96 -t 32 -r 32

# Client (perf-4) — connects to perf-3 mgmt IP
numactl --cpunodebind=netdev:enp195s0f3 ib_write_bw \
  -d rocep195s0f3 -m 4096 -s 1048576 --run_infinitely \
  -q <N> -x 1 --report_gbits \
  --planes=19.1.0.1,19.2.0.1,19.3.0.1,19.4.0.1 \
  -D 1 --tclass=96 -t 32 -r 32 \
  10.30.52.66
```

### RL configuration (on perf-4)
```bash
cd /root/gaurav

# Enable RL
./nicctl.bin debug update pipeline internal rate-limit \
  --lif 18 --enable --rate-bps 196000000000 \
  --burst-bytes 256000 --max-ports 4 --window-lg2 10 \
  --bdf 0000:c1:00.0

# Disable RL
./nicctl.bin debug update pipeline internal rate-limit \
  --lif 18 --disable --rate-bps 1 --burst-bytes 1 \
  --max-ports 4 --window-lg2 10 --bdf 0000:c1:00.0

# Check RL state
./nicctl.bin show pipeline internal rate-limit \
  --lif 18 --port-id 0 --bdf 0000:c1:00.0

# Check port status bytes (live verification)
eth_dbgtool memrd 0x10164a400 8
# 0x00 = GREEN (port not throttled), 0x01 = RED (throttled)
```

### Path count
```bash
nicctl update pipeline rdma path -p 0 --count <N> --bdf 0000:c1:00.0
```

### Clean state between runs
```bash
nicctl clear pipeline internal state --bdf 0000:c1:00.0
nicctl clear rdma internal queue --bdf 0000:c1:00.0
eth_dbgtool memwr 0x10164a400 8 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00
```

### Port flap commands (on perf-4)
```bash
# Port UUID mapping on perf-4:
# eth1/1/1 → enp196s0 (19.1.0.1): 049081a7-6f58-4242-4242-000011010001
# eth1/1/3 → enp197s0 (19.2.0.1): 049081a7-6f58-4242-4242-000011010003
# eth1/1/5 → enp198s0 (19.3.0.1): 049081a7-6f58-4242-4242-000011010005
# eth1/1/7 → enp199s0 (19.4.0.1): 049081a7-6f58-4242-4242-000011010007

nicctl update port -p 049081a7-6f58-4242-4242-000011010001 --admin-state down
nicctl update port -p 049081a7-6f58-4242-4242-000011010001 --admin-state up
```

---

## Test Results

### 1. HOLB Validation — Matches Gaurav's Numbers ✅

4×200G, 1 path, unidirectional. Theoretical max = 776 Gbps.

| QPs | No RL | RL @ 196 Gbps | Match Gaurav? |
|-----|-------|---------------|---------------|
| 7 | ~670 (HOLB) | **759** | ✅ (Gaurav: 670/759) |
| 8 | 777 | 774 | ✅ |
| 15 | ~727 (HOLB) | **774** | ✅ (Gaurav: 727/774) |
| 16 | 777 | 774 | ✅ |

With 2 paths (partial bootstrap without RL, full with RL):

| QPs | Paths | No RL | RL |
|-----|-------|-------|-----|
| 7 | 2 | ~670 | **774** |
| 15 | 2 | ~727 | **774** |

---

### 2. RCN Test — Orthogonal to RL ✅

RCN neither helps nor hurts HOLB. RL benefit is identical with/without RCN.

| QPs | No RCN / No RL | No RCN / RL | RCN on / No RL | RCN on / RL |
|-----|----------------|-------------|----------------|-------------|
| 7 | 670 (HOLB) | 760 | 677 (HOLB) | 760 |
| 15 | 727 (HOLB) | 774 | 724 (HOLB) | 776 |

---

### 3. Port Flap — 1 Port Down

Theoretical max with 3 active ports = ~588 Gbps (196×3).

| QPs | Paths | Steady (No RL) | Steady (RL) | Port Down (No RL) | Port Down (RL) | RL helps? |
|-----|-------|----------------|-------------|-------------------|----------------|-----------|
| 7 | 1 | 676 (HOLB) | 760 | 342 | **571** | ✅ Yes |
| 7 | 2 | 683 (HOLB) | 776 | 468 | **473** | ✅ Yes (marginal) |
| 7 | 4 | 778 | 776 | 583 | 582 | ➡️ Neutral |
| 7 | 8 | 778 | 776 | 583 | 582 | ➡️ Neutral |
| 8 | 1 | 778 | 776 | 389 | **582** | ✅ Yes |
| 8 | 2 | 778 | 776 | 424 | **566** | ✅ Yes |
| 8 | 4 | 778 | 776 | 583 | 582 | ➡️ Neutral |
| 8 | 8 | 778 | 776 | 583 | 582 | ➡️ Neutral |

**Key finding:** With 1-2 paths, RL recovers close to 196×3=588 Gbps.
With 4+ paths, path diversity self-heals without RL.

---

### 4. Port Flap — 2 Ports Down

Theoretical max with 2 active ports = ~392 Gbps (196×2).

| QPs | Paths | Steady (No RL) | Steady (RL) | 2 Ports Down (No RL) | 2 Ports Down (RL) | RL helps? |
|-----|-------|----------------|-------------|----------------------|-------------------|-----------|
| 7 | 1 | 676 (HOLB) | 760 | 329 | **388** | ✅ Yes |
| 7 | 2 | 683 (HOLB) | 776 | ~318 | ~325 | ➡️ Neutral |
| 7 | 4 | 778 | 776 | 389 | 388 | ➡️ Neutral |
| 7 | 8 | 778 | 776 | 389 | 387 | ➡️ Neutral |
| 8 | 1 | 778 | 776 | 389 | 389 | ➡️ Neutral |
| 8 | 2 | 778 | 776 | ~345 | ~348 | ➡️ Neutral |
| 8 | 4 | 778 | 776 | 389 | 388 | ➡️ Neutral |
| 8 | 8 | 778 | 776 | 389 | 387 | ➡️ Neutral |

*(2-path cases: averaged over 3 runs, ±15 Gbps variability)*

**Key finding:** 7QP, 1 path, 2 ports down — RL recovers to 388 ≈ 196×2 ✅
All other 2-port-down cases: neutral (either self-heals via path diversity or both equally degraded).

---

## Known Issues / Bugs Found

### Bug 1: Port status misdirection during port-down

**Symptom:** When a port goes admin DOWN, its RL status byte stays `0x00` (GREEN) because no traffic flows through it → meter never drains → tbkt stays at burst → appears available.

**Effect:** Port blocking may redirect traffic TO the physically-down port → packets dropped → lower throughput than expected.

**Root cause:** RL's port status byte is only updated by METER_UPDATE (via traffic flow). A port that's DOWN never gets traffic → never gets marked RED → appears as a valid redirect target.

**Fix:** When `nicctl update port --admin-state down` is called, nicmgr should immediately write `0x01` to that port's status byte in HBM:
```c
// In nicmgr port-down handler:
uint64_t status_base; // from pic_rl_port_status region
pal_mem_wr(status_base + port_index, &red_byte, 1, 0);
// where red_byte = 0x01
```

### Bug 2: LLC meter init dead code path (fixed in patch)

`eth_rdma_impl_pic_rl_llc_meter_init()` was called from `eth_rdma_impl_init()` which is never reached at runtime. Fixed by moving the call to `eth_rdma_impl_lif_init()` gated on `lif_id == 1`. Patch: `/home/pradeept/llc_rl_lif_init_fix.patch`.

---

## HBM Addresses (perf-3 and perf-4)

```
meter_base:   0x1016d1040
status_base:  0x10164a400

Port meters (64 bytes each):
  Port 0: 0x1016d1040
  Port 1: 0x1016d1080
  Port 2: 0x1016d10c0
  Port 3: 0x1016d1100

Port status bytes (1 byte each):
  Port 0: 0x10164a400
  Port 1: 0x10164a401
  Port 2: 0x10164a402
  Port 3: 0x10164a403
```

---

## Pending Tests (not yet done)

### Nataraj's CLI — path inactivation trigger
```bash
nicctl update pipeline rdma congestion-control \
  --active-path-per-path-group disable --bdf 0000:c1:00.0
```
Available in build `1.130.0-a-106+`. Not on current nodes. This triggers path inactivation via ECN/SACK to create sparse QPs → HOLB, then verify RL resolves it.

Steps to get the binary:
1. Build from `1.130-a` master which has the feature
2. Or ask Nataraj to share `nicctl.bin`

### Test matrix for Nataraj's CLI
- Enable `--active-path-per-path-group disable`
- Run traffic with ECN (tclass=96)
- Observe paths inactivate → sparse QPs → HOLB
- Enable RL → verify HOLB resolution
- Test with different QP counts (7, 8, 15, 16) and path counts (2, 4, 8)

---

## Automation Scripts

Located on `sw-dev9.pensando.io`:
```
/tmp/run_rl_matrix.sh        # Full QP×path matrix (no RL vs RL)
/tmp/run_rcn_test.sh         # RCN orthogonality test
/tmp/run_port_down_scenarios.sh  # Port flap scenarios
/tmp/run_8qp_paths.sh        # 8 QP, 1/2/4/8 paths, port flap
/tmp/run_7qp_paths.sh        # 7 QP, 1/2/4/8 paths, port flap
/tmp/run_2port_down.sh       # 2 ports down, 7/8 QPs
/tmp/verify_2path_2port.sh   # 3-run verification of 2-path 2-port case
```
