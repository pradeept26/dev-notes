---
name: Hydra GTest Workflow
description: Automated testing for Hydra RDMA using Google Test framework with helper scripts
type: reference
---

## Hydra GTest Testing (Vulcano ASIC)

**Quick Reference:** Complete documentation at `~/dev-notes/pensando-sw/testing/hydra-gtest.md`

### Fully Automated Build (BEST - Use This!)

**One command to handle everything:**
```bash
# Complete automation: tmux, submodules, docker, assets, build
~/dev-notes/pensando-sw/scripts/build-hydra-gtest.sh

# With options
~/dev-notes/pensando-sw/scripts/build-hydra-gtest.sh --clean       # Clean before build
~/dev-notes/pensando-sw/scripts/build-hydra-gtest.sh --skip-submod # Skip submodule update
~/dev-notes/pensando-sw/scripts/build-hydra-gtest.sh --skip-assets # Skip pull-assets
```

**What `build-hydra-gtest.sh` does:**
1. Checks/creates tmux session
2. Updates submodules (outside Docker)
3. Cleans up old Docker containers
4. Launches Docker
5. Pulls assets
6. Builds gtest (15-30 min)

### Manual Helper Scripts (Inside Docker)

**Location:** `~/dev-notes/pensando-sw/scripts/run-hydra-gtest.sh`

```bash
# Build gtests (inside Docker)
~/dev-notes/pensando-sw/scripts/run-hydra-gtest.sh build

# Run specific test
~/dev-notes/pensando-sw/scripts/run-hydra-gtest.sh test resp_rx.invalid_path_id_nak

# Run all tests
~/dev-notes/pensando-sw/scripts/run-hydra-gtest.sh all

# Check status
~/dev-notes/pensando-sw/scripts/run-hydra-gtest.sh status
```

### Manual Commands (Inside Docker)

**IMPORTANT:** `~/dev-notes/` scripts NOT accessible inside Docker. Use direct commands.

**Build (inside Docker at /sw):**
```bash
# Two-step build (CORRECT approach)
cd /sw
make -f Makefile.ainic rudra-vulcano-hydra-sw-emu   # Step 1: Build sw-emu
make -f Makefile.ainic rudra-vulcano-hydra-gtest    # Step 2: Build gtest

# Alternative single command (calls both above)
make -f Makefile.build build-rudra-vulcano-hydra-gtest
```

**Run (inside Docker at /sw/nic):**
```bash
cd /sw/nic
DMA_MODE=uxdma ASIC=vulcano P4_PROGRAM=hydra \
  GTEST_BINARY=/sw/nic/rudra/build/hydra/x86_64/sim/rudra/vulcano/bin/hydra_gtest \
  GTEST_FILTER='resp_rx.invalid_path_id_nak' \
  PROFILE=qemu \
  LOG_FILE=hydra_gtest.log \
  rudra/test/tools/run_ionic_gtest.sh
```

### Key Test Suites

- `resp_rx.*` - Response receive tests (path validation, NAK generation)
- `req_tx.*` - Request transmit tests
- `mp_resp_rx.*` - Multi-path response tests
- `req_retx_*.*` - Retransmission tests (SACK, RTO, RNR)

### Important Tests

- `resp_rx.invalid_path_id_nak` - Path mismatch validation (NAK generation)
- `mp_resp_rx.*` - Multi-path packet handling across 3 paths

### Google Test Filter Syntax

```bash
# Single test
GTEST_FILTER='resp_rx.invalid_path_id_nak'

# All in suite
GTEST_FILTER='resp_rx.*'

# Exclude scale tests (slow)
GTEST_FILTER='-*scale*'

# Combine
GTEST_FILTER='resp_rx.*:-*scale*'
```

### Logs

- Test output: `$LOG_FILE` (specified in command)
- Simulator: `/tmp/model.log`
- Nicmgr: `/obfl/nicmgr.log` or `/var/log/pensando/nicmgr.log`

### Why This Matters

**Context:** Hydra implements Meta RoCE (multipath RDMA) requiring extensive testing of:
- Path validation (invalid path_id must NAK)
- Multi-path packet handling (out-of-order, interleaving)
- Retransmission logic (SACK, timeout, RNR)
- DMA operations and payload verification

**How to apply:** Use gtests for unit testing P4 datapath logic, RDMA protocol handling, and multipath correctness before hardware testing.
