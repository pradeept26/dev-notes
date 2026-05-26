# Meta RoCE Testing Guide

This document describes the test infrastructure for the Meta RoCE Hydra pipeline: what tests exist, how they are organized, how to run them, and how to debug test failures.

For test-case discovery, grep the test trees directly:
- gtest: `nic/rudra/test/hydra/gtest/`
- DOL: `dol/rudra/test/rdma_hydra/`
- P4+ unit: `nic/rudra/src/hydra/p4/p4plus-16/meta_roce/{tx,rx}/test/`

---

## 1. Test Categories

Meta RoCE has three layers of testing, each targeting a different abstraction level:

### 1.1 P4 Unit Tests (pytest)

**Location:** `nic/rudra/src/hydra/p4/p4plus-16/meta_roce/{tx,rx}/test/`

Pure-P4 stage-level tests that exercise individual P4 actions and tables in isolation. Use the P4 test harness to push synthetic PHV input and verify output PHV state and DMA commands.

**Examples:**
- `tx/test/test_s1_sqwqe_write.py` — S1 WQE write path
- `tx/test/test_s2_req_tx_path_sel.py` — S2 path selection
- `tx/test/test_s2_req_tx_path_sel_breakout.py` — Path selection with port breakout
- `rx/test/test_s3_path_rx.py` — S3 RX path processing

**When to use:** Quickest feedback loop for P4 logic changes; no firmware build needed.

### 1.2 Hydra gtest (C++ Google Test)

**Location:** `nic/rudra/test/hydra/gtest/`

C++ unit tests built on top of the pipeline simulator. They construct full PHV state, drive the pipeline, and verify outputs (packets, completions, CB updates).

**Test files (~46 test cases total):**

| File | Coverage |
|------|----------|
| `req_tx_test.cc` | Requester TX: WRITE/SEND new WQE path, ACK handling, NAK cases |
| `req_retx_brnr_test.cc` | Requester retransmission on BRNR |
| `req_retx_rto_test.cc` | Requester retransmission on RTO timeout |
| `req_retx_sack_test.cc` | Requester retransmission on SACK |
| `resp_rx_test.cc` | Responder RX: data path, FSN validation, MR checks |
| `resp_rx_sack_tx.cc` | Responder RX → TX SACK generation |
| `mp_resp_rx_test.cc` | Multi-packet responder RX handling |
| `scale_pkt_req_tx.cc` | Scale: many packets through requester TX |
| `scale_pkt_resp_rx.cc` | Scale: many packets through responder RX |

**When to use:** Verify pipeline correctness for new features or regressions; fast (~minutes); no testbed required.

**Build and run:**
```bash
# Use the build-gtest skill or directly:
cd nic/rudra/test/hydra/gtest
make
./hydra_gtest.gtest
```

Or via skill: `build-gtest`, `gtest`.

### 1.3 DOL (Day in the Life of) Tests

**Location:** `dol/rudra/test/rdma_hydra/`

End-to-end functional tests using the DOL framework. They configure real QPs, post WQEs, generate packets through the pipeline simulator, and verify packet content, completions, and statistics.

**Test list:** 44 tests in `rdma_hydra.mlist` covering:

| Category | Sample Test Names |
|----------|-------------------|
| **Basic WRITE** | `RDMA_REQ_TX_WRITE_ONLY`, `RDMA_REQ_TX_WRITE_FIRST_LAST`, `RDMA_REQ_TX_WRITE_FIRST_MID_LAST` |
| **WRITE Edge Cases** | `RDMA_REQ_TX_WRITE_ONLY_ZERO_LENGTH`, `RDMA_REQ_TX_WRITE_*_2SGE` |
| **WRITE with Immediate** | `RDMA_REQ_TX_WRITE_IMM_*` |
| **SEND** | `RDMA_REQ_TX_SEND_*` |
| **Responder RX** | `RDMA_RESP_RX_WRITE_*`, `RDMA_RESP_RX_SEND_*` |
| **Out-of-Order / Duplicate** | `RDMA_RX_DUPLICATE_*`, `RDMA_RESP_RX_*_OOR_*` |
| **Congestion Control** | `req_cc_qwnd_sack_md*` (AIMD multiplicative decrease scenarios) |
| **Retransmission** | `req_tx_rdma_drop_sack`, `req_tx_send_cc_sack_aimd` |
| **Error Handling** | `req_tx_nak`, `req_tx_rnr` |

**When to use:** Validate end-to-end behavior; confirm protocol compliance; regression testing before firmware deployment.

**Run via skill:** `dol`
```
"run dol rdma_write tests"
"run dol testcase RDMA_REQ_TX_WRITE_ONLY"
"run dol RDMA_REQ_TX_WRITE_ONLY with debug"
```

---

## 2. Test Infrastructure

### 2.1 Build Container

All tests run inside the `pensando/nic` Docker container. Start with:
```bash
cd $HYDRA_SW && make docker/shell
```

The build skills (`build-gtest`, `gtest`, `dol`) auto-detect the running container. These skills are defined in `nic/rudra/src/hydra/.claude/skills/`.

### 2.2 Test Harness Files

| Test Category | File | Purpose |
|---------------|------|---------|
| P4 unit tests | `meta_roce/test/meta_roce_defines.py` | Test-side opcodes, constants, struct sizes |
| P4 unit tests | `meta_roce/test/defines.py` | Generic RDMA test constants |
| gtest | `nic/rudra/test/hydra/gtest/hydra_gtest.hpp` | Common test fixture and helper macros |
| gtest | `nic/rudra/test/hydra/gtest/main.cc` | gtest entry point |
| DOL | `dol/rudra/test/rdma_hydra/rdma_hydra.py` | DOL test driver module |

### 2.3 mlist Format

DOL tests are organized in `.mlist` files. Each module entry specifies:
```yaml
- module:
    name    : RDMA_REQ_TX_WRITE_ONLY      # Test case identifier
    enable  : True                          # Whether to run
    package : test.rdma_hydra               # Python package
    module  : req_tx_write_only             # Python module file
    spec    : req_tx_write_only.testspec    # Test specification file
    ignore  : False
```

The `--testcase` parameter to the dol skill matches the `name:` field.

---

## 3. Coverage

### 3.1 What Is Covered

**P4 unit tests (pytest):**
- Individual stage actions in TX S1, S2 and RX S3
- Path selection logic including port breakout

**gtest:**
- Requester TX: WRITE-only, ACK processing, retransmission (BRNR/RTO/SACK)
- Responder RX: data path, FSN validation, SACK generation
- Multi-packet flows
- Scale tests (many packets through pipeline)

**DOL:**
- All WRITE patterns: ONLY, FIRST_LAST, FIRST_MID_LAST, with/without IMM
- SEND patterns
- 2-SGE configurations
- Out-of-order and duplicate handling
- Congestion control scenarios (CC + SACK + multiplicative decrease)
- RNR conditions
- NAK error handling

### 3.2 Coverage Gaps

Areas not yet well-tested for **implemented** features (verify against current state of `rdma_hydra.mlist`):
- **Multipath failover:** Limited tests for path inactivation and port failover under RTO
- **Mixed traffic:** Concurrent SEND + WRITE on same QP
- **Long-running tests:** Most tests are short-burst; sustained throughput scenarios are rare
- **Path bootstrap:** Fast Start path activation timing

When adding a new feature, check whether tests exist in these gap areas.

**Not listed here** (these are feature gaps, not test gaps): RDMA Read, Atomic operations, and Tag multiplexing are unimplemented per the spec — see [`07-feature-status.md`](07-feature-status.md).

---

## 4. Running Tests

### 4.1 Quick Smoke Test

```bash
# Single DOL test
"run dol testcase RDMA_REQ_TX_WRITE_ONLY"

# Single DOL test with debug logs
"run dol RDMA_REQ_TX_WRITE_ONLY with debug"
```

### 4.2 Full Regression

```bash
# All DOL rdma_write tests
"run dol rdma_write tests"

# All gtest tests
"build the gtest"   # then:
"run gtest"
```

### 4.3 Targeted Testing

| Change in pipeline area | Run these tests |
|--------------------------|------------------|
| TX S0-S2 (entry, path sel) | `req_tx_test.cc` + `RDMA_REQ_TX_WRITE_ONLY*` |
| TX S3-S4 (FSN, retx) | `req_retx_*.cc` + `req_tx_rdma_drop_sack` |
| TX S5-S7 (headers, DMA) | `req_tx_test.cc` (verify_pkt_content variants) |
| RX S0-S3 (FSN validation) | `resp_rx_test.cc` + `RDMA_RX_DUPLICATE_*` |
| RX ACK path | `resp_rx_sack_tx.cc` + `req_cc_qwnd_sack_md*` |
| Congestion control | `req_tx_send_cc_sack_aimd` + `req_cc_qwnd_sack_md*` |
| RNR handling | `req_tx_rnr` + `req_retx_brnr_test.cc` |

---

## 5. Debugging Test Failures

### 5.1 gtest Failures

1. **Read the failure message.** gtest prints the first failing assertion.
2. **Check expected vs actual PHV / packet bytes.** Failures typically show field-by-field diff.
3. **Run with debugger:** `gdb ./hydra_gtest.gtest --gtest_filter="*test_name*"`
4. **Check test setup:** Verify the test fixture initializes CB state correctly for the path under test.

### 5.2 DOL Failures

1. **Check `model.log`** in the test output directory — has full pipeline trace.
2. **Re-run with `--debug`** for verbose output (warning: large log files).
3. **Compare packet content:** DOL tests verify wire bytes; check for mismatched fields.
4. **Verify CB state:** DOL has dump utilities to inspect CB state at key points.

### 5.3 Common Test Failure Patterns

| Symptom | Likely Cause |
|---------|--------------|
| Wrong packet opcode | Misconfigured pred vector or wrong action dispatched |
| Missing ACK | Path scheduler not ringing doorbell; check ACK ring PI/CI |
| FSN mismatch | snd.nxt or rcv.nxt initialized incorrectly |
| Wrong CB field after pipeline | Stage skip mask or pred bit incorrectly gating updates |
| DMA command missing | Slot not allocated in correct stage; check slot table |
| MR access error | Test setup didn't register MR with required access flags |

### 5.4 Adding New Tests

When adding a new feature:
1. **Start with P4 unit test** if the change is stage-local
2. **Add gtest** if the change spans multiple stages or affects packet content
3. **Add DOL test** if the change is end-to-end visible (new opcode, new completion path)
4. **Update mlist** with new entry if adding DOL test
5. **Document coverage gap closure** by updating Section 3.2 above

---

For per-test descriptions and which CB fields/opcodes each test exercises, read the test source files directly — most have header comments explaining intent.
