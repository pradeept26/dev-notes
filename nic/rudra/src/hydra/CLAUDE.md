# Hydra P4+ Firmware

Meta RoCE (RDMA over Converged Ethernet) implementation for Vulcano ASIC.

## Directory Structure

- `p4/` - P4+ dataplane programs (TXDMA, RXDMA pipelines)
- `cli/` - CLI commands and handlers
- `impl/` - Core implementation (QP state machine, packet processing)
- `nicmgr/` - NIC management and LIF configuration
- `test/` - Unit and integration tests
- `tools/` - Build and debug utilities
- `.claude/skills/` - Build, test, and debug skills

## Skills

This directory provides the full Hydra developer workflow — build, test, deploy, testbed access, and debugging.

### Build & Test
- **build** — Build Hydra firmware (P4+, C++)
- **build-gtest** — Build Google Test binaries
- **gtest** — Run hydra C++ Google Test cases
- **p4plus-unit-test** — Run P4+ pytest unit tests (capsim) per stage; emits insn/cycle counts
- **dol** — Run DOL (Day in the Life of) test cases
- **pull-assets** — Pull P4 compiler and other build assets
- **qemu-test** — Launch QEMU vulcano sim and run RDMA perftest in the guest VM

### Deploy
- **deploy** — Deploy firmware to a testbed (transfer + update + optional reset)
- **transfer** — Transfer firmware image to testbed hosts (no update)
- **bringup** — Wait for NICs after reset and run setup commands

### Testbed
- **connect** — Launch tmux session with SSH to testbed nodes
- **run** — Execute commands on all testbed nodes
- **nic-status** — Check NIC status on testbed

### Debug
- **debug-meta-roce** — Debug Meta RoCE issues
- **decode-exception** — Decode MPU exceptions from logs

For lab-side operations (BMC power control, BIOS settings, ACS configuration), see `~/ws/ai-lab/projects/hydra/CLAUDE.md`.

## Build Environment

Build commands run inside the `pensando/nic` Docker container. Scripts auto-detect the container or use `$HYDRA_CONTAINER`.

## P4+ Programs

Hydra uses multiple P4+ programs across different pipelines:

- **TXDMA**: Outbound packet processing, QP scheduling
- **RXDMA**: Inbound packet processing, completion handling
- **SXDMA**: Shared DMA operations

Each pipeline has its own ASM output in `nic/rudra/src/conf/*_asm/`.
