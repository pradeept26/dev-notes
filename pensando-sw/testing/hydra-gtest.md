# Hydra GTest - Vulcano ASIC

Automated testing for hydra RDMA implementation using Google Test framework.

## Quick Start

### Fully Automated Build (Recommended)

**One-command build from scratch:**
```bash
# Complete automation: tmux, submodules, docker, assets, build
~/dev-notes/pensando-sw/scripts/build-hydra-gtest.sh

# With options
~/dev-notes/pensando-sw/scripts/build-hydra-gtest.sh --clean          # Clean before build
~/dev-notes/pensando-sw/scripts/build-hydra-gtest.sh --skip-submod    # Skip submodule update
~/dev-notes/pensando-sw/scripts/build-hydra-gtest.sh --skip-assets    # Skip pull-assets
~/dev-notes/pensando-sw/scripts/build-hydra-gtest.sh --clean-docker   # Clean up old Docker containers
```

**What it does:**
1. ✓ Checks/creates tmux session `pensando-sw`
2. ✓ Updates git submodules (outside Docker) - skip with `--skip-submod`
3. ✓ Optionally cleans up old Docker containers (use `--clean-docker`)
4. ✓ Launches Docker container
5. ✓ Pulls assets (inside Docker) - skip with `--skip-assets`
6. ✓ Optionally runs make clean (use `--clean`)
7. ✓ Builds hydra gtest (15-30 minutes)
8. ✓ Reports completion with next steps

### Manual Commands (Inside Docker)

**IMPORTANT:** Scripts in `~/dev-notes/` are NOT accessible inside Docker.
Use direct commands inside Docker at `/sw` or `/sw/nic`:

```bash
# Build (at /sw)
cd /sw
make -f Makefile.ainic rudra-vulcano-hydra-sw-emu
make -f Makefile.ainic rudra-vulcano-hydra-gtest

# Run specific test (at /sw/nic)
cd /sw/nic
DMA_MODE=uxdma ASIC=vulcano P4_PROGRAM=hydra \
  GTEST_BINARY=/sw/nic/rudra/build/hydra/x86_64/sim/rudra/vulcano/bin/hydra_gtest \
  GTEST_FILTER='resp_rx.invalid_path_id_nak' \
  PROFILE=qemu \
  LOG_FILE=hydra_gtest.log \
  rudra/test/tools/run_ionic_gtest.sh

# Run all tests (excluding scale)
DMA_MODE=uxdma ASIC=vulcano P4_PROGRAM=hydra \
  GTEST_BINARY=/sw/nic/rudra/build/hydra/x86_64/sim/rudra/vulcano/bin/hydra_gtest \
  GTEST_FILTER='-*scale*' \
  PROFILE=qemu \
  LOG_FILE=hydra_gtest_all.log \
  rudra/test/tools/run_ionic_gtest.sh

# Check if binary exists
ls -lh /sw/nic/rudra/build/hydra/x86_64/sim/rudra/vulcano/bin/hydra_gtest
```

## Manual Build & Run (if needed)

### Build Commands

**Inside Docker at /sw:**
```bash
# Single command - make handles all dependencies
make -f Makefile.ainic rudra-vulcano-hydra-gtest
```

**What it builds (in order):**
1. `rudra-vulcano-hydra-sw-emu` - Software emulator (RTOS firmware for simulation)
2. `libpdsproto_rudra.lib` - Protocol library (P4 generated files)
3. `libe2e_driver.lib` - End-to-end driver library
4. Gtest binaries: `hydra_gtest`, `hydra_gtest_aq`

**Why single command?**
The Makefile.ainic target has dependencies, so make automatically builds them in the correct order. Building dependencies separately can cause missing header file errors.

**Output locations:**
- Gtest binaries: `/sw/nic/rudra/build/hydra/x86_64/sim/rudra/vulcano/bin/`
- Libraries: `/sw/nic/build/x86_64/sim/rudra/vulcano/lib/`

### Run Commands

**All commands must be run inside Docker at /sw/nic**

#### Single Test
```bash
cd /sw/nic
DMA_MODE=uxdma ASIC=vulcano P4_PROGRAM=hydra \
  GTEST_BINARY=/sw/nic/rudra/build/hydra/x86_64/sim/rudra/vulcano/bin/hydra_gtest \
  GTEST_FILTER='resp_rx.invalid_path_id_nak' \
  PROFILE=qemu \
  LOG_FILE=hydra_gtest.log \
  rudra/test/tools/run_ionic_gtest.sh
```

#### Test Suite (all resp_rx tests)
```bash
DMA_MODE=uxdma ASIC=vulcano P4_PROGRAM=hydra \
  GTEST_BINARY=/sw/nic/rudra/build/hydra/x86_64/sim/rudra/vulcano/bin/hydra_gtest \
  GTEST_FILTER='resp_rx.*:-*scale*' \
  PROFILE=qemu \
  LOG_FILE=hydra_gtest_resp_rx.log \
  rudra/test/tools/run_ionic_gtest.sh
```

#### All Tests (excluding scale)
```bash
DMA_MODE=uxdma ASIC=vulcano P4_PROGRAM=hydra \
  GTEST_BINARY=/sw/nic/rudra/build/hydra/x86_64/sim/rudra/vulcano/bin/hydra_gtest \
  GTEST_FILTER='-*scale*' \
  PROFILE=qemu \
  LOG_FILE=hydra_gtest_all.log \
  rudra/test/tools/run_ionic_gtest.sh
```

## Test Suites

### Available Test Classes

| Suite | Description | Test Count |
|-------|-------------|------------|
| `resp_rx.*` | Response receive tests (path validation, NAK generation) | ~6 enabled |
| `req_tx.*` | Request transmit tests | Multiple |
| `mp_resp_rx.*` | Multi-path response tests (3-path configurations) | ~8 |
| `req_retx_brnr.*` | Request retransmission - RNR (Receiver Not Ready) | Multiple |
| `req_retx_sack.*` | Request retransmission - SACK (Selective ACK) | Multiple |
| `req_retx_rto.*` | Request retransmission - RTO (Timeout) | Multiple |

### Key Tests

**Path Validation:**
- `resp_rx.invalid_path_id_nak` - Validates NAK generation for invalid path_id
- `req_tx.DISABLED_recv_nak_pathid_uns_verify_error_completion` - RX path mismatch error handling (disabled)

**Multi-path:**
- `mp_resp_rx.write_only_verify_payload_path_1` - Write on path 1
- `mp_resp_rx.write_only_verify_payload_path_2` - Write on path 2
- `mp_resp_rx.write_lmf_verify_payload_and_ack_path_210` - Out-of-order multi-path

## Google Test Filter Syntax

```bash
# Single test
GTEST_FILTER='resp_rx.invalid_path_id_nak'

# All tests in suite
GTEST_FILTER='resp_rx.*'

# Exclude patterns (scale tests are slow)
GTEST_FILTER='-*scale*'

# Combine include and exclude
GTEST_FILTER='resp_rx.*:-*scale*'

# Multiple suites
GTEST_FILTER='resp_rx.*:req_tx.*'
```

## Logs and Debugging

### Log Locations

| Log | Location | Purpose |
|-----|----------|---------|
| Test output | `$LOG_FILE` (e.g., `hydra_gtest.log`) | Google Test results, assertions |
| Simulator | `/tmp/model.log` | vul_model simulator output |
| Nicmgr | `/obfl/nicmgr.log` | Nicmgr initialization and runtime |
| Nicmgr alt | `/var/log/pensando/nicmgr.log` | Alternative nicmgr location |

### Debugging Failed Tests

```bash
# Check for core dumps
ls -lh /tmp/core.*

# View simulator logs
tail -100 /tmp/model.log

# Check nicmgr initialization
grep -i "init completed" /obfl/nicmgr.log

# View test output
cat hydra_gtest.log
```

## Build Artifacts

### Binary Locations

```
/sw/build_vulcano_hydra_gtest.tar.gz              # Build package
/sw/nic/rudra/build/hydra/x86_64/sim/rudra/vulcano/bin/
├── hydra_gtest                                    # Main gtest binary
└── hydra_gtest_aq                                 # AQ (Admin Queue) tests

/sw/nic/build/x86_64/sim/rudra/vulcano/lib/
├── libe2e_driver.so                              # E2E driver
└── libpdsproto_rudra.so                          # Protocol library
```

### Clean Build

```bash
cd /sw
rm -f /sw/build_vulcano_hydra_gtest.tar.gz
rm -rf /sw/nic/rudra/build/hydra/x86_64/sim/rudra/vulcano/
```

Or use the helper script:
```bash
~/dev-notes/pensando-sw/scripts/run-hydra-gtest.sh clean
```

## Test Architecture

### Test Framework Components

1. **RDMA Driver** (`g_rdma_driver`) - Simulates RDMA operations
2. **Queue Pairs** - `g_qp1`, `g_qp2` (single path), `g_mp_qp1` (multi-path)
3. **Memory Regions** - TX/RX buffers registered with HW
4. **Packet Construction** - Helper functions to build RoCE packets
5. **Validation** - Payload DMA verification, packet comparison

### Test Flow

```
1. Setup (main.cc)
   ├── Init RDMA driver
   ├── Create LIF (eth0)
   ├── Register memory regions
   ├── Create queue pairs
   └── Build header templates

2. Test Execution
   ├── Construct test packet
   ├── Send from uplink
   ├── Verify response (ACK/NAK)
   └── Validate payload DMA

3. Teardown
   └── Cleanup resources
```

## References

### Source Files

| File | Purpose |
|------|---------|
| `nic/rudra/test/hydra/gtest/*.cc` | Test implementations |
| `nic/rudra/test/hydra/gtest/main.cc` | Test framework setup |
| `nic/rudra/test/hydra/hydra_gtest_base.{cc,hpp}` | Base classes and helpers |
| `nic/rudra/test/tools/run_ionic_gtest.sh` | Test runner script |
| `nic/rudra/src/hydra/p4/p4plus-16/meta_roce/rx/*.p4` | RX path P4 code |
| `nic/rudra/src/hydra/p4/p4plus-16/meta_roce/include/rdma_types.p4` | NAK codes, constants |

### Build Definitions

| File | Lines | Purpose |
|------|-------|---------|
| `Makefile.build` | 1816-1820 | Top-level gtest build target |
| `Makefile.ainic` | 208-210 | Vulcano hydra gtest recipe |
| `nic/rudra/test/hydra/gtest/Makefile` | - | Gtest compilation |

## Common Issues

### Build Failures

**Issue:** "Container already exists"
```bash
# Clean up old containers
docker ps -a | grep "$(whoami)_" | awk '{print $1}' | xargs -r docker stop | xargs -r docker rm
```

**Issue:** "Submodule not initialized"
```bash
# Outside Docker
git submodule update --init --recursive
```

### Test Failures

**Issue:** "Nicmgr failed to initialize"
```bash
# Check nicmgr logs
cat /obfl/nicmgr.log
# Look for error messages before "init completed"
```

**Issue:** "Model not responding"
```bash
# Check if vul_model is running
ps aux | grep vul_model

# Check model logs
tail -100 /tmp/model.log
```

## Expected Test Output

```
[==========] Running 2 tests from 1 test suite.
[----------] Global test environment set-up.
[----------] 2 tests from resp_rx/0, resp_rx/1
[ RUN      ] resp_rx/0.invalid_path_id_nak
[       OK ] resp_rx/0.invalid_path_id_nak (45 ms)
[ RUN      ] resp_rx/1.invalid_path_id_nak
[       OK ] resp_rx/1.invalid_path_id_nak (42 ms)
[----------] 2 tests from resp_rx/0, resp_rx/1 (87 ms total)

[----------] Global test environment tear-down
[==========] 2 tests from 1 test suite ran. (87 ms total)
[  PASSED  ] 2 tests.
```

## Test Development

To add new tests:

1. Add test to appropriate `*_test.cc` file
2. Use `TEST_P` for parameterized tests
3. Follow existing patterns for packet construction
4. Validate both packet output and payload DMA
5. Rebuild and run

Example:
```cpp
TEST_P(resp_rx, my_new_test)
{
    meta_roce_qp *qp = (meta_roce_qp *)GetParam();
    std::vector<uint8_t> pkt;

    // Test implementation
    constructRxWritePkt(pkt, *qp, ...);
    sendPktFromUplink(0, pkt);

    ASSERT_EQ(validatePayload(...), 1);
}
```
