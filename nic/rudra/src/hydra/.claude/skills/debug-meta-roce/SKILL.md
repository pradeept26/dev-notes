---
name: debug-meta-roce
description: "Debug Meta RoCE (RDMA) issues in the Hydra pipeline. Use when user says debug roce, debug rdma, meta roce issue, qp error, rdma error, rdma timeout, connection failed, check rdma status, or stuck QP."
---

# Debug Meta RoCE Skill

Debug Meta RoCE (RDMA) issues in the Hydra pipeline.

## Usage Examples

- "debug rdma connection failure"
- "why is QP in error state"
- "debug roce timeout on smc1"
- "debug roce on smc1 nic 06:00" — debug specific NIC by BDF
- "debug meta roce smc1 benic1" — debug specific NIC by device name

## Parameters

| Parameter | Format | Description |
|-----------|--------|-------------|
| testbed | Required | Testbed name or path to YAML |
| nic | Optional | NIC identifier: BDF (e.g., "06:00"), device name (e.g., "benic1"), or port number (e.g., "1") |
| mode | Optional | "perf" or "correctness" (auto-detected from symptom keywords) |

**Mode Detection:**
- **Performance mode** triggered by: "slow", "throughput", "bandwidth", "latency", "performance", "Gbps", "perf", "line rate"
- **Correctness mode** (default): errors, timeouts, connection failures, QP state issues, NAKs, drops

## Knowledge Base

**MANDATORY — read before debugging:**
- `p4/p4plus-16/meta_roce/docs/06-debugging.md` — **primary reference**: anomaly decision tree, stuck test workflow, error-disabled bitmap decode, cross-node correlation, complete nicctl command reference, known benign conditions
- `p4/p4plus-16/meta_roce/docs/10-performance-debugging.md` — performance debugging workflows, asicmon commands, bottleneck identification
- `p4/p4plus-16/meta_roce/docs/01-protocol.md` — wire protocol, opcodes, sequence numbers
- CB headers under `p4/p4plus-16/meta_roce/include/` — exact field layouts

## Steps

1. Identify the symptom, testbed, and optional NIC identifier from the user's request.
2. Determine mode (performance vs correctness) based on symptom keywords.
3. **Read `docs/06-debugging.md`** for the debugging reference applicable to the symptom.
4. Delegate execution to a subagent so verbose debug output stays out of the main context. Spawn a `general-purpose` Agent with a self-contained prompt:
   - Tell it which testbed to SSH to and what symptom to investigate.
   - If a NIC identifier was specified:
     - Identify card UUID via `sudo nicctl show card` filtered by BDF
     - Scope nicctl commands with `-c <card-uuid>`
     - Scope asicmon with `PAL_CARD_UUID=<card-uuid>`
   
   **Branch on mode:**
   
   **IF mode is "perf" (performance debugging):**
   - Get card UUID per node
   - Verify traffic is running before collecting metrics
   - Run `PAL_CARD_UUID=<uuid> asicmon -b` for PCIe bandwidth
   - Ask user permission before `PAL_CARD_UUID=<uuid> asicmon -P` (resets counters)
   - Check `nicctl show port -c <card-uuid>` for port speed
   - Check `lspci -s <bdf> -vvv | grep LnkSta` for PCIe gen/width
   - Determine if at line rate; interpret TXS XOFF and drops per `docs/10-performance-debugging.md`
   - Return summary: line rate status, PCIe BW, wire BW, bottleneck identification
   
   **ELSE (correctness mode):**
   - **Always start with `sudo nicctl show pipeline internal rdma anomalies`**
   - **Use the Anomaly Decision Tree in `docs/06-debugging.md`** to interpret each anomaly
   - For stuck issues: follow the **Stuck Test Debugging Workflow** (7 phases from sender SQ → responder ACK ring)
   - For error-disabled QPs: follow the **QP Error-Disabled Debugging** section with bitmap decode
   - For cross-node issues: follow **Cross-Node Correlation** rules
   - Return a **short diagnostic summary** (under ~200 words): symptom, anomaly findings with classification, cross-node findings if applicable, and next steps.

5. Relay the agent's summary to the user.

Only run commands directly in the main context if the user explicitly asks for raw output or interactive debugging.

## Documentation

See `p4/p4plus-16/meta_roce/docs/` for:
- `00-overview.md` — Protocol overview
- `01-protocol.md` — Wire protocol, opcodes
- `02-tx-pipeline.md` — TX pipeline
- `03-rx-pipeline.md` — RX pipeline
- `04-controlplane.md` — Control plane
- `05-testing.md` — Test infrastructure
- **`06-debugging.md` — Complete debugging reference (anomaly decision tree, stuck workflow, error-disabled decode, cross-node correlation, command reference)**
- `07-feature-status.md` — Feature status
- `08-asic-differences.md` — ASIC differences
- `09-p4-engineering-principles.md` — P4+ engineering principles
- `10-performance-debugging.md` — Performance debugging
