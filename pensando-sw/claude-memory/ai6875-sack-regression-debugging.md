---
name: AI-6875 SACK Regression Debugging Learnings
description: Key findings and techniques from debugging the SACK retransmit over-firing regression (AI-6875)
type: project
originSessionId: 52a4c8d7-ece8-461f-bd47-1415de128069
---
# AI-6875 SACK Retransmit Regression — Key Learnings

## Root Cause (Confirmed)
Commit `21e6dae5de0` (AI-6746, Igor Druzhinin, PR #117383/#117439) — "silence boot time PICS ECC
interrupts" — moved `vulcano_block_init` before `asic_pgm_init` in `vulcano_init.c`, violating
the documented ordering invariant (blat TE registers first, then RMW). This caused the SACK
retransmit engine to use corrupted SRAM state → 7x over-firing → 27% BW collapse under drops.

**Fix:** Move `vulcano_block_init` back to after `asic_pgm_init` (validated, Igor confirmed).
File: `nic/sdk/rtos-shared/src/lib/asicpd/vulcano/vulcano_init.c`

## SMC Cannot Reproduce Back-to-Back SACK Bugs
The switch-based topology on SMC (through Micas switch) prevents the CWND collapse from manifesting.
SACK over-firing bugs that cause step-function BW collapse under drops **require back-to-back
topology** (like Kenya). SMC shows only ~1-3% degradation under drops even on affected builds.

**Why:** The switch adds RTT and changes congestion dynamics, preventing the CWND collapse that
amplifies the SACK retransmit issue.

## Bisect Methodology with Hourly Builds
All hourly builds available at `/vol/builds/hourly/<version>/`:
- Format: `rudra-bundle/release-artifacts/hydra/vulcano/ainic_bundle_<version>.tar.gz`
- Contains: `firmware/ainic_fw_vulcano.tar` + `host_sw_pkg.tar.gz` (independent)
- Can install host_sw_pkg separately from FW: always install matching version after FW flash

**Per-card targeted firmware update (key for mixed-FW testing):**
```bash
nicctl update firmware -i <fw.tar> -c <card-uuid>
nicctl reset card -c <card-uuid>
```

**Binary bisect on a-10 through a-33:** Only 23 builds, ~3 iterations to isolate.

## Useful Debugging Commands

### SACK retransmit stats (on sender LIF):
```bash
LIF=$(nicctl show lif | awk 'NR>2{print $1; exit}')
nicctl show rdma queue-pair path statistics --lif $LIF | grep -E "SACK retransmit|RTO retransmit"
```

### ECC interrupt verification (after firmware flash):
```bash
nicctl show card interrupts --all | grep -iE 'pics|ecc'
# Healthy: no PICS ECC entries (QSPI ECC is unrelated/benign)
```

### Boot log check (NIC Zephyr RTOS logs):
```bash
nicctl show card logs --persistent
# Look for: no ECC errors in first 10 seconds of boot
```

### rdma-drop injection:
```bash
nicctl debug update pipeline internal rdma-drop \
  --enable --drop-type rand --frequency 2000 --packet-types 0x18
nicctl debug update pipeline internal rdma-drop --disable
```

## Build Gotcha: Stale ainic-rtos cmake cache
When switching branches and rebuilding, always clear the ainic-rtos cmake cache first:
```bash
docker exec <CONTAINER> rm -rf /sw/platform/rtos-sw/external/ainic-rtos/build
```
Otherwise, the stale cache (from pull-assets or previous build) uses wrong Zephyr SDK version
(e.g., v4.0.0 instead of v4.1.0), causing cmake errors like:
`COREDUMP_TYPE_CALLBACK_POOLED_BUFFERED not in enum list`

**How to apply:**
1. Clone branch in sw-1 workspace
2. `docker exec <CONTAINER> rm -rf /sw/platform/rtos-sw/external/ainic-rtos/build`
3. Then `nohup docker exec -w /sw <CONTAINER> make -f Makefile.build build-rudra-vulcano-hydra-ainic-fw`
