# Hydra GTest Quick Reference

**Copy/paste this for quick reference inside Docker**

## Build Commands (at /sw)

```bash
cd /sw

# Single command - make handles all dependencies
# Builds: sw-emu → libpdsproto_rudra.lib → libe2e_driver.lib → gtest
make -f Makefile.ainic rudra-vulcano-hydra-gtest

# Check binary exists
ls -lh /sw/nic/rudra/build/hydra/x86_64/sim/rudra/vulcano/bin/hydra_gtest
```

## Run Tests (at /sw/nic)

```bash
cd /sw/nic

# Single test - Path mismatch validation
DMA_MODE=uxdma ASIC=vulcano P4_PROGRAM=hydra \
  GTEST_BINARY=/sw/nic/rudra/build/hydra/x86_64/sim/rudra/vulcano/bin/hydra_gtest \
  GTEST_FILTER='resp_rx.invalid_path_id_nak' \
  PROFILE=qemu \
  LOG_FILE=hydra_gtest.log \
  rudra/test/tools/run_ionic_gtest.sh

# All resp_rx tests
DMA_MODE=uxdma ASIC=vulcano P4_PROGRAM=hydra \
  GTEST_BINARY=/sw/nic/rudra/build/hydra/x86_64/sim/rudra/vulcano/bin/hydra_gtest \
  GTEST_FILTER='resp_rx.*:-*scale*' \
  PROFILE=qemu \
  LOG_FILE=hydra_gtest_resp_rx.log \
  rudra/test/tools/run_ionic_gtest.sh

# All tests (excluding scale)
DMA_MODE=uxdma ASIC=vulcano P4_PROGRAM=hydra \
  GTEST_BINARY=/sw/nic/rudra/build/hydra/x86_64/sim/rudra/vulcano/bin/hydra_gtest \
  GTEST_FILTER='-*scale*' \
  PROFILE=qemu \
  LOG_FILE=hydra_gtest_all.log \
  rudra/test/tools/run_ionic_gtest.sh
```

## Test Filter Syntax

```bash
# Single test
GTEST_FILTER='resp_rx.invalid_path_id_nak'

# All in suite
GTEST_FILTER='resp_rx.*'

# Exclude scale tests (they're slow)
GTEST_FILTER='-*scale*'

# Combine include and exclude
GTEST_FILTER='resp_rx.*:-*scale*'

# Multiple suites
GTEST_FILTER='resp_rx.*:req_tx.*'
```

## Available Test Suites

| Suite | Description | Count |
|-------|-------------|-------|
| `resp_rx.*` | Response receive (path validation, NAK) | ~6 |
| `req_tx.*` | Request transmit | Multiple |
| `mp_resp_rx.*` | Multi-path (3 paths) | ~8 |
| `req_retx_brnr.*` | Retransmission - RNR | Multiple |
| `req_retx_sack.*` | Retransmission - SACK | Multiple |
| `req_retx_rto.*` | Retransmission - Timeout | Multiple |

## Key Tests

- `resp_rx.invalid_path_id_nak` - Path mismatch NAK validation
- `mp_resp_rx.write_only_verify_payload_path_1` - Multi-path packet handling
- `mp_resp_rx.write_lmf_verify_payload_and_ack_path_210` - Out-of-order multipath

## Logs

```bash
# View test output
cat hydra_gtest.log

# Check simulator
tail -100 /tmp/model.log

# Check nicmgr
grep -i "init completed" /obfl/nicmgr.log
cat /var/log/pensando/nicmgr.log
```

## Clean Build

```bash
cd /sw
make clean
make -f Makefile.ainic clean
rm -rf /sw/nic/rudra/build/hydra/
```

## Expected Output (Success)

```
[==========] Running 2 tests from 1 test suite.
[----------] 2 tests from resp_rx/0, resp_rx/1
[ RUN      ] resp_rx/0.invalid_path_id_nak
[       OK ] resp_rx/0.invalid_path_id_nak (42 ms)
[ RUN      ] resp_rx/1.invalid_path_id_nak
[       OK ] resp_rx/1.invalid_path_id_nak (45 ms)
[----------] 2 tests from resp_rx (87 ms total)
[==========] 2 tests from 1 test suite ran. (87 ms total)
[  PASSED  ] 2 tests.
```
