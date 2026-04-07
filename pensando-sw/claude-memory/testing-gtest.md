---
name: Hydra GTest Workflow
description: Automated testing for Hydra RDMA using Google Test framework with helper scripts
type: reference
---

## Hydra GTest Testing (Vulcano ASIC)

**Quick Reference:** Complete documentation at `~/dev-notes/pensando-sw/testing/hydra-gtest.md`

### Helper Script (Recommended)

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

# Clean build artifacts
~/dev-notes/pensando-sw/scripts/run-hydra-gtest.sh clean
```

### Manual Commands (if needed)

**Build (inside Docker at /sw):**
```bash
make -f Makefile.build build-rudra-vulcano-hydra-gtest
# Output: /sw/build_vulcano_hydra_gtest.tar.gz
```

**Run (inside Docker at /sw/nic):**
```bash
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
