---
name: Hydra GTest Workflow
description: Automated testing for Hydra RDMA using Google Test framework
type: reference
---

## Hydra GTest Testing (Vulcano ASIC)

### Use Repo Skills (Recommended)
GTest build and run are now repo skills from PR #115193:
- `/build-gtest` — Build the gtest binary
- `/gtest` — Run gtest cases with filter support

### Manual Commands (Inside Docker)

**Build (inside Docker at /sw):**
```bash
cd /sw
make -f Makefile.build build-rudra-vulcano-hydra-gtest
```

**Run (inside Docker at /sw/nic) - MUST use sudo:**
```bash
cd /sw/nic
sudo DMA_MODE=uxdma ASIC=vulcano P4_PROGRAM=hydra \
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

### Google Test Filter Syntax
```bash
GTEST_FILTER='resp_rx.invalid_path_id_nak'    # Single test
GTEST_FILTER='resp_rx.*'                       # All in suite
GTEST_FILTER='-*scale*'                        # Exclude scale tests
GTEST_FILTER='resp_rx.*:-*scale*'              # Combine
```

### Logs
- Test output: `$LOG_FILE` (specified in command)
- Simulator: `/tmp/model.log`
- Nicmgr: `/obfl/nicmgr.log` or `/var/log/pensando/nicmgr.log`
