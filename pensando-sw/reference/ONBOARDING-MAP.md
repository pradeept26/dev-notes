# Pensando SW — Complete Onboarding Map

**Author:** Pradeep Thangaraju
**Last Updated:** 2026-04-29
**Purpose:** End-to-end guide for new engineers joining Hydra/RDMA development on the Pensando AI NIC platform.

---

## Table of Contents

1. [Big Picture — What Are We Building?](#1-big-picture)
2. [Repository Layout](#2-repository-layout)
3. [Architecture — How the Pieces Fit](#3-architecture)
4. [The P4 Datapath (Where Packets Live)](#4-p4-datapath)
5. [The RDMA Plugin (Control Plane for RDMA)](#5-rdma-plugin)
6. [ASIC Variants — Vulcano vs Salina](#6-asic-variants)
7. [Build System — From Source to Firmware](#7-build-system)
8. [Development Environment Setup](#8-dev-environment-setup)
9. [Testing Pyramid](#9-testing-pyramid)
10. [Firmware Update & Deployment](#10-firmware-deployment)
11. [Hardware Lab & Setups](#11-hardware-lab)
12. [Debugging & Diagnostics](#12-debugging)
13. [Day-to-Day Workflow](#13-daily-workflow)
14. [Common Pitfalls](#14-common-pitfalls)
15. [Key Contacts & Resources](#15-resources)

---

## 1. Big Picture — What Are We Building? <a name="1-big-picture"></a>

We build **AI NICs** (Network Interface Cards) optimized for GPU-to-GPU RDMA traffic in AI training clusters.

```
┌─────────────────────────────────────────────────────────────────┐
│                     AI TRAINING CLUSTER                        │
│                                                                 │
│  ┌──────────┐   RDMA/RoCE    ┌──────────┐                     │
│  │  GPU Node │ ◄────────────► │  GPU Node │                    │
│  │  (Host)   │                │  (Host)   │                    │
│  │           │                │           │                    │
│  │  ┌─────┐  │   800G Link   │  ┌─────┐  │                    │
│  │  │ NIC │──┼───────────────┼──│ NIC │  │                    │
│  │  │(AI) │  │    Switch      │  │(AI) │  │                    │
│  │  └─────┘  │   Fabric       │  └─────┘  │                    │
│  └──────────┘                └──────────┘                     │
└─────────────────────────────────────────────────────────────────┘
```

**Key terms:**
- **RDMA** — Remote Direct Memory Access. GPU writes directly to another GPU's memory, bypassing the CPU.
- **RoCE** — RDMA over Converged Ethernet. RDMA running on standard Ethernet instead of InfiniBand.
- **Meta RoCE** — Meta's multipath extension to RoCE. Multiple network paths per QP for resilience and load balancing.
- **QP** — Queue Pair. The fundamental RDMA communication channel (Send Queue + Receive Queue).
- **RCCL** — ROCm Communication Collective Library. AMD's GPU collective communication library (AllReduce, etc.).

**Our NIC product:**
- **Project name:** Hydra
- **Pipeline:** Rudra (the programmable pipeline framework)
- **ASICs:** Vulcano (current gen), Salina/Pollara (newer gen)
- **Firmware OS:** Zephyr RTOS (runs on the NIC's ARM cores)

---

## 2. Repository Layout <a name="2-repository-layout"></a>

The monorepo at `/ws/<user>/ws/usr/src/github.com/pensando/sw`:

```
sw/                                     ← Repo root
├── nic/                                ← NIC firmware + host tools (OUR MAIN AREA)
│   ├── rudra/
│   │   ├── src/
│   │   │   └── hydra/                  ← ★ HYDRA PROJECT (90% of your work is here)
│   │   │       ├── p4/                 ← P4 datapath programs
│   │   │       │   ├── p4-16/          ← Ingress/egress P4 (packet parsing, forwarding)
│   │   │       │   ├── p4plus-16/      ← P4+ programs (RDMA TX/RX engines)
│   │   │       │   │   ├── rdma/       ← Core RDMA P4+ logic
│   │   │       │   │   └── meta_roce/  ← Meta RoCE multipath extensions
│   │   │       │   │       ├── rx/     ← RX pipeline (s0-s7 stages)
│   │   │       │   │       ├── tx/     ← TX pipeline (s0-s7 stages)
│   │   │       │   │       └── common/ ← Shared P4 code (path_bmp, etc.)
│   │   │       │   └── plugin/         ← P4 plugin definitions
│   │   │       ├── nicmgr/
│   │   │       │   └── plugin/
│   │   │       │       └── rdma/       ← ★ RDMA Control Plane Plugin
│   │   │       │           ├── admincmd_handler.c   ← Admin queue command processing
│   │   │       │           ├── devcmd_handler.c     ← Device command processing
│   │   │       │           ├── init.c               ← RDMA subsystem init
│   │   │       │           ├── lif_init.c           ← LIF initialization
│   │   │       │           ├── rdma_common.c        ← Shared utilities
│   │   │       │           ├── rdma_drop.c          ← Drop counters/debug
│   │   │       │           ├── traffic_profile.c    ← Traffic profiling
│   │   │       │           ├── vulcano/             ← Vulcano-specific code
│   │   │       │           └── salina/              ← Salina-specific code
│   │   │       ├── dp/                 ← Datapath pipeline init (C++)
│   │   │       ├── impl/              ← QoS and pipeline implementation
│   │   │       ├── include/           ← Shared headers
│   │   │       │   ├── meta_roce_defines.h
│   │   │       │   ├── rdma_defines.h
│   │   │       │   └── rdma_types.h
│   │   │       ├── grpc/              ← gRPC service definitions
│   │   │       ├── protos/            ← Protobuf definitions
│   │   │       ├── svc/               ← Service implementations
│   │   │       ├── cli/               ← CLI implementations
│   │   │       ├── test/              ← Test packet definitions
│   │   │       └── docs/              ← Project documentation
│   │   └── test/
│   │       ├── hydra/
│   │       │   ├── hydra_gtest_base.cc  ← GTest infrastructure
│   │       │   └── gtest/               ← ★ UNIT TESTS
│   │       │       ├── resp_rx_test.cc      ← Response RX tests
│   │       │       ├── req_tx_test.cc       ← Request TX tests
│   │       │       ├── mp_resp_rx_test.cc   ← Multi-path tests
│   │       │       ├── req_retx_sack_test.cc ← Retransmit SACK
│   │       │       ├── req_retx_rto_test.cc  ← Retransmit timeout
│   │       │       ├── req_retx_brnr_test.cc ← RNR retry
│   │       │       ├── scale_pkt_*.cc        ← Scale tests
│   │       │       └── aq/                   ← Admin queue tests
│   │       └── tools/
│   │           ├── run_ionic_gtest.sh  ← GTest runner script
│   │           └── dol/
│   │               └── rundol.sh       ← DOL test runner
│   ├── conf/                   ← Configuration files
│   └── Makefile               ← NIC-level Makefile
│
├── dol/                        ← DOL (Data-plane Offload Library) Tests
│   └── rudra/test/
│       └── rdma_hydra/         ← ★ HYDRA DOL TESTS (Python)
│           ├── rdma_hydra.py               ← Test module entry
│           ├── req_tx_send_first_last.py   ← Send test
│           ├── req_tx_nak.py               ← NAK test
│           ├── req_tx_rnr.py               ← RNR test
│           └── *.testspec                  ← Test specifications
│
├── platform/
│   └── rtos-sw/                ← ★ Zephyr RTOS Firmware
│       ├── CMakeLists.txt      ← Top-level build
│       ├── hw/                 ← Hardware abstraction
│       ├── modules/            ← Kernel modules
│       ├── configs/            ← Zephyr configs
│       └── include/            ← RTOS headers
│
├── Makefile                    ← Top-level Make
├── Makefile.build              ← Full build targets (use this!)
└── Makefile.ainic              ← AI NIC specific targets
```

**Rule of thumb:** If you're editing RDMA logic, you're in `nic/rudra/src/hydra/`.

---

## 3. Architecture — How the Pieces Fit <a name="3-architecture"></a>

```
┌─────────────────────────── HOST (Linux Server) ──────────────────────────┐
│                                                                          │
│  ┌────────┐   ┌────────────┐   ┌──────────────────────────────────────┐ │
│  │  GPU   │   │  User App  │   │  nicctl (management CLI)            │ │
│  │ (RCCL) │   │  (libibverbs│   │  - show card/port/version          │ │
│  └───┬────┘   │   + rdma)  │   │  - update firmware                 │ │
│      │        └─────┬──────┘   │  - reset card                      │ │
│      │              │          └──────────────┬───────────────────────┘ │
│      │              │                         │                         │
│  ┌───▼──────────────▼─────────────────────────▼─────────────────────┐  │
│  │                    Host Driver (ionic_rdma)                       │  │
│  │  - Queue Pair management     - Memory registration               │  │
│  │  - Doorbell ringing          - Admin Queue commands               │  │
│  └──────────────────────────────────┬───────────────────────────────┘  │
│                                     │ PCIe                              │
└─────────────────────────────────────┼──────────────────────────────────┘
                                      │
┌─────────────────────────── NIC (AI NIC) ─────────────────────────────────┐
│                                                                          │
│  ┌───────────────────── ARM Cores (Zephyr RTOS) ──────────────────────┐ │
│  │                                                                     │ │
│  │  ┌──────────────────────────────────────────────────────────────┐  │ │
│  │  │  NicMgr (Management Daemon)                                  │  │ │
│  │  │  ├── RDMA Plugin (our code!)                                 │  │ │
│  │  │  │   ├── admincmd_handler.c  — Create QP, Modify QP, etc.   │  │ │
│  │  │  │   ├── devcmd_handler.c    — Device-level commands         │  │ │
│  │  │  │   ├── lif_init.c          — LIF (Logical Interface) init  │  │ │
│  │  │  │   └── rdma_common.c       — Shared helpers                │  │ │
│  │  │  └── Other Plugins (eth, storage...)                         │  │ │
│  │  └──────────────────────────────────────────────────────────────┘  │ │
│  └─────────────────────────────────────────────────────────────────────┘ │
│                                                                          │
│  ┌─────────────── P4 Programmable Pipeline (ASIC) ────────────────────┐ │
│  │                                                                     │ │
│  │  ┌────────────┐   ┌──────────────────────────┐   ┌──────────────┐ │ │
│  │  │  Ingress   │   │  P4+ Engines              │   │   Egress     │ │ │
│  │  │  Parser    │   │                            │   │   Deparser   │ │ │
│  │  │  (p4-16/)  │──►│  TX Pipeline (s0-s7)      │──►│   (p4-16/)   │ │ │
│  │  │            │   │   - Read SQCB              │   │              │ │ │
│  │  │  Classify  │   │   - Process WQE            │   │  Add headers │ │ │
│  │  │  Route     │   │   - Build RDMA headers     │   │  Checksum    │ │ │
│  │  │  Forward   │   │   - DMA payload            │   │  Transmit    │ │ │
│  │  │            │   │                            │   │              │ │ │
│  │  │            │   │  RX Pipeline (s0-s7)      │   │              │ │ │
│  │  │            │   │   - Parse RDMA headers     │   │              │ │ │
│  │  │            │   │   - Validate PSN/path      │   │              │ │ │
│  │  │            │   │   - DMA to host memory     │   │              │ │ │
│  │  │            │   │   - Generate ACK/NAK       │   │              │ │ │
│  │  │            │   │                            │   │              │ │ │
│  │  │            │   │  Meta RoCE Extensions     │   │              │ │ │
│  │  │            │   │   - Multipath handling     │   │              │ │ │
│  │  │            │   │   - Path bitmap mgmt      │   │              │ │ │
│  │  │            │   │   - SACK generation        │   │              │ │ │
│  │  └────────────┘   └──────────────────────────┘   └──────────────┘ │ │
│  └─────────────────────────────────────────────────────────────────────┘ │
│                                                                          │
│  ┌───────────────────── Network Interface ────────────────────────────┐ │
│  │  SerDes ◄──► Transceiver ◄──► 800G Ethernet Link                  │ │
│  └─────────────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────────────┘
```

**Data flow for an RDMA Write:**
1. App posts a Work Queue Entry (WQE) to the Send Queue
2. Rings the doorbell → NIC hardware picks up the WQE
3. **TX Pipeline (P4+):** Reads SQCB → processes WQE → builds RoCE/Meta-RoCE headers → DMAs payload from host → sends packet
4. **Network:** Packet traverses the switch fabric (800G Ethernet)
5. **RX Pipeline (P4+):** Receives packet → validates PSN, path_id → DMAs payload to remote host memory → generates ACK
6. ACK flows back → TX side updates completion queue

---

## 4. The P4 Datapath (Where Packets Live) <a name="4-p4-datapath"></a>

### What is P4?

P4 is a programming language for network data planes. Our NICs have a **programmable ASIC** — instead of fixed hardware, we write P4 code that defines exactly how packets are processed.

### Pipeline Structure

Each pipeline has **8 stages (s0-s7)**. Each stage can read/write tables, modify packet headers, and trigger DMA operations.

```
TX Pipeline (sending RDMA operations):
  s0: Read SQ context block (SQCB) — fetch QP state
  s1: Process WQE — determine operation type (Write, Send, Read)
  s2: Fetch scatter-gather entries — locate data in host memory
  s3: Build transport headers — RoCE/BTH/RETH headers
  s4: Path selection — choose network path (Meta RoCE multipath)
  s5: Add headers — assemble final packet, congestion control
  s6: Checksum / encryption (PSP)
  s7: Doorbell / completion

RX Pipeline (receiving RDMA operations):
  s0: Read RQ context block (RQCB) — fetch QP state
  s1: Validate PSN (Packet Sequence Number) — in-order delivery
  s2: Parse RDMA payload — decode Write/Send/Read
  s3: DMA setup — prepare DMA descriptor for host memory write
  s4: Update MSN (Message Sequence Number) tracking
  s5: Generate ACK/NAK — Meta RoCE SACK bitmap
  s6: Completion queue update
  s7: Cleanup / doorbell
```

### Key P4 Files

| File Pattern | What It Does |
|---|---|
| `meta_roce_tx_s0.p4` | TX stage 0 — SQ context read |
| `meta_roce_tx_s5_add_headers_write.p4` | TX stage 5 — build Write packet headers |
| `meta_roce_rx_s1.p4` | RX stage 1 — PSN validation |
| `meta_roce_rx_s5.p4` | RX stage 5 — ACK/NAK generation, MSN tracking |
| `meta_roce_defines.p4` (also `.h`) | Constants, struct sizes, MSN window config |
| `path_bmp.p4` | Multipath path bitmap operations |
| `rdma_comp.p4` | Completion queue logic |

### Control Blocks (CB)

The P4 pipeline reads/writes **context blocks** stored in NIC memory:

- **SQCB** — Send Queue Control Block (TX state per QP)
- **RQCB** — Receive Queue Control Block (RX state per QP)
- **RRQCB** — Remote Read Queue CB
- **RSQCB** — Remote Send Queue CB
- **CQ** — Completion Queue
- **EQ** — Event Queue

---

## 5. The RDMA Plugin (Control Plane for RDMA) <a name="5-rdma-plugin"></a>

The RDMA plugin runs on the NIC's ARM cores (Zephyr RTOS). It handles QP lifecycle management — the "slow path" that sets up state for the "fast path" (P4 pipeline).

### Key Files

| File | Responsibility |
|---|---|
| `admincmd_handler.c` | Processes Admin Queue commands from the host driver: Create QP, Modify QP, Destroy QP, Create MR, etc. |
| `devcmd_handler.c` | Device-level commands: LIF create/destroy, feature negotiation |
| `init.c` | RDMA subsystem initialization |
| `lif_init.c` | LIF (Logical Interface) initialization — allocates resources per LIF |
| `rdma_common.c` | Shared utilities: QP state transitions, error handling |
| `rdma_drop.c` | Drop counter management and debugging |
| `traffic_profile.c` | Traffic profiling and statistics |

### QP State Machine

```
      ┌───────┐    Create QP     ┌────────┐
      │ RESET │ ───────────────► │  INIT  │
      └───────┘                  └───┬────┘
                                     │ Modify QP (INIT→RTR)
                                     ▼
                                ┌─────────┐
                                │   RTR    │  (Ready to Receive)
                                └───┬─────┘
                                    │ Modify QP (RTR→RTS)
                                    ▼
                                ┌─────────┐
                                │   RTS    │  (Ready to Send — ACTIVE)
                                └───┬─────┘
                                    │ Error or Destroy
                                    ▼
                              ┌──────────┐
                              │  ERROR/  │
                              │ DESTROY  │
                              └──────────┘
```

Each Modify QP transition programs the P4 context blocks with peer addressing, path info, and congestion control parameters.

---

## 6. ASIC Variants — Vulcano vs Salina <a name="6-asic-variants"></a>

| Feature | Vulcano | Salina (Pollara) |
|---|---|---|
| Generation | Current | Newer |
| CPU | ARM (Zephyr RTOS) | ARM A35 (Zephyr RTOS) |
| Link Speed | 800G | 800G |
| Build target prefix | `build-rudra-vulcano-hydra-*` | `build-rudra-salina-hydra-*` |
| Firmware output | `ainic_fw_vulcano.tar` | `ainic_fw_salina.tar` |
| ASIC-specific code | `nicmgr/plugin/rdma/vulcano/` | `nicmgr/plugin/rdma/salina/` |
| Firmware update | `nicctl update firmware -i <tar>` | Same |

Most P4 and RDMA plugin code is shared. ASIC-specific differences are isolated in subdirectories.

---

## 7. Build System — From Source to Firmware <a name="7-build-system"></a>

### The Golden Rule

> **ALL builds happen inside Docker. No exceptions.**

### Build Flow

```
┌──────────────────── OUTSIDE Docker (your shell) ─────────────────────┐
│                                                                       │
│  1. git submodule update --init --recursive                          │
│  2. cd nic && make docker/shell                                      │
│                                                                       │
└───────────────────────────┬───────────────────────────────────────────┘
                            │ Enters Docker container
                            ▼
┌──────────────────── INSIDE Docker (at /sw) ──────────────────────────┐
│                                                                       │
│  3. make pull-assets              ← Download prebuilt dependencies   │
│  4. make -f Makefile.build <target>  ← Build                         │
│                                                                       │
│  Targets you'll use:                                                  │
│  ┌───────────────────────────────────────────────────────────────┐   │
│  │ DEVELOPMENT:                                                   │   │
│  │   build-rudra-vulcano-hydra-gtest     → GTest binary          │   │
│  │   build-rudra-vulcano-hydra-sw-emu    → DOL simulation build  │   │
│  │                                                                │   │
│  │ HARDWARE DEPLOYMENT:                                           │   │
│  │   build-rudra-vulcano-hydra-ainic-fw  → Firmware tarball      │   │
│  │   build-rudra-salina-hydra-ainic-bundle → Salina firmware     │   │
│  │                                                                │   │
│  │ INCREMENTAL (fast, after small changes):                       │   │
│  │   make -C nic PIPELINE=rudra P4_PROGRAM=hydra                 │   │
│  │        ARCH=x86_64 ASIC=vulcano package                       │   │
│  └───────────────────────────────────────────────────────────────┘   │
│                                                                       │
│  Outputs (at /sw):                                                    │
│    ainic_fw_vulcano.tar          ← Firmware for deployment           │
│    build_vulcano_hydra_gtest.tar.gz  ← GTest binary                  │
│    zephyr_vulcano_hydra_sim.tar.gz   ← Simulator                     │
│                                                                       │
└───────────────────────────────────────────────────────────────────────┘
```

### Build Commands Cheat Sheet

```bash
# === PREPARATION (always do these first) ===

# Outside Docker: update submodules
git submodule update --init --recursive

# Clean old Docker containers
docker ps -a | grep "$(whoami)_" | awk '{print $1}' | xargs -r docker stop | xargs -r docker rm

# Launch Docker
cd /ws/<user>/ws/usr/src/github.com/pensando/sw/nic && make docker/shell

# Inside Docker: pull assets
cd /sw && make pull-assets

# === VULCANO BUILDS ===

# GTest build (unit tests)
make -f Makefile.build build-rudra-vulcano-hydra-gtest

# DOL build (integration tests)
make -f Makefile.build build-rudra-vulcano-hydra-sw-emu

# Firmware build (for hardware)
make -f Makefile.build build-rudra-vulcano-hydra-ainic-fw

# Quick incremental (after small code changes — fastest)
make -C nic PIPELINE=rudra P4_PROGRAM=hydra ARCH=x86_64 ASIC=vulcano package

# === SALINA BUILDS ===

# Quick A35 firmware (fastest for iterating)
make PIPELINE=rudra P4_PROGRAM=hydra rudra-salina-ainic-a35-fw

# Full bundle (for deployment)
make -f Makefile.build build-rudra-salina-hydra-ainic-bundle

# === CLEAN BUILD (when things are broken) ===
make clean
make -f Makefile.ainic clean
make pull-assets
# Then re-run desired build target
```

### Build Times (approximate)

| Target | Time | When to Use |
|---|---|---|
| Incremental `package` | 2-10 min | Small code changes |
| GTest | 15-30 min | Full unit test build |
| DOL (sw-emu) | 20-40 min | Integration test build |
| Firmware (ainic-fw) | 30-60 min | Hardware deployment |
| Clean + full build | 45-90 min | Branch switch, broken state |

---

## 8. Development Environment Setup <a name="8-dev-environment-setup"></a>

### First-Time Setup

```bash
# 1. Clone the repo (already done on dev servers)
# Repo lives at: /ws/<user>/ws/usr/src/github.com/pensando/sw

# 2. Set up tmux (CRITICAL — protects long builds from SSH drops)
tmux new-session -s pensando-sw

# 3. Update submodules
cd /ws/<user>/ws/usr/src/github.com/pensando/sw
git submodule update --init --recursive

# 4. Launch Docker
cd nic && make docker/shell

# 5. Inside Docker, pull assets
cd /sw && make pull-assets

# 6. Build (pick your target)
make -f Makefile.build build-rudra-vulcano-hydra-gtest
```

### tmux — Your Safety Net

**ALWAYS use tmux for builds and tests.** SSH disconnects will kill your 30-minute build otherwise.

```bash
# Session management
tmux new-session -s pensando-sw    # Create
tmux attach -t pensando-sw         # Reattach after disconnect
tmux ls                            # List sessions
Ctrl+b d                           # Detach (keeps running)
Ctrl+b c                           # New window
Ctrl+b n / Ctrl+b p                # Next/prev window
Ctrl+b [0-9]                       # Switch to window N
```

### Docker — How It Works

The Docker container mounts the repo at `/sw`. Your host path `/ws/<user>/.../sw` becomes `/sw` inside Docker. Edits are visible immediately in both directions — no copy needed.

```
Host filesystem:  /ws/<user>/ws/usr/src/github.com/pensando/sw/
                               │
                               │  (bind mount)
                               ▼
Docker filesystem: /sw/
```

**How to tell if you're inside Docker:**
- `pwd` shows `/sw/...` → You're in Docker
- `pwd` shows `/ws/...` → You're on the host

---

## 9. Testing Pyramid <a name="9-testing-pyramid"></a>

```
                    ┌────────────────────┐
                    │   IB/RDMA Tests    │  ← Real hardware, real traffic
                    │  (45-60+ minutes)  │     ib_write_bw, RCCL tests
                    ├────────────────────┤
                    │    DOL Tests       │  ← Full simulation, Python
                    │  (10-30 minutes)   │     End-to-end packet flow
                    ├────────────────────┤
                    │  GTests (Unit)     │  ← QEMU simulator, C++
                    │  (5-15 minutes)    │     Individual P4 stage tests
                    └────────────────────┘
```

### GTest (Unit Tests) — Fastest Feedback

Tests individual P4 pipeline stages with a QEMU-based simulator.

```bash
# Build (inside Docker at /sw)
make -f Makefile.build build-rudra-vulcano-hydra-gtest

# Run (inside Docker at /sw/nic) — MUST use sudo
sudo DMA_MODE=uxdma ASIC=vulcano P4_PROGRAM=hydra \
  GTEST_BINARY=/sw/nic/rudra/build/hydra/x86_64/sim/rudra/vulcano/bin/hydra_gtest \
  GTEST_FILTER='resp_rx.*' \
  PROFILE=qemu \
  LOG_FILE=hydra_gtest.log \
  rudra/test/tools/run_ionic_gtest.sh
```

**Key test suites:**

| Suite | What It Tests |
|---|---|
| `resp_rx.*` | RX pipeline — PSN validation, NAK generation, path checking |
| `req_tx.*` | TX pipeline — WQE processing, header building |
| `mp_resp_rx.*` | Multipath RX — multi-path packet handling |
| `req_retx_sack.*` | Retransmission — SACK-based retransmit |
| `req_retx_rto.*` | Retransmission — timeout-based retransmit |
| `req_retx_brnr.*` | Retransmission — RNR (Receiver Not Ready) retry |
| `scale_pkt_*` | Scale tests — high QP counts (slow, skip with `-*scale*`) |

**GTest filter syntax:**
```bash
GTEST_FILTER='resp_rx.invalid_path_id_nak'   # Single test
GTEST_FILTER='resp_rx.*'                      # All in suite
GTEST_FILTER='-*scale*'                       # Exclude scale tests
GTEST_FILTER='resp_rx.*:-*scale*'             # Combine include/exclude
```

**Test source files:** `nic/rudra/test/hydra/gtest/*.cc`

### DOL Tests (Integration) — Full Packet Flow

Tests complete packet flow through the simulated pipeline. Written in Python.

```bash
# Build (inside Docker at /sw)
make -f Makefile.build build-rudra-vulcano-hydra-sw-emu

# Run (inside Docker at /sw/nic)
PIPELINE=rudra ASIC=vulcano P4_PROGRAM=hydra PCIEMGR_IF=1 DMA_MODE=uxdma PROFILE=qemu \
  rudra/test/tools/dol/rundol.sh \
  --pipeline rudra \
  --topo rdma_hydra \
  --feature rdma_hydra \
  --sub rdma_write \
  --nohntap
```

**DOL test files:** `dol/rudra/test/rdma_hydra/*.py`

Available `--sub` options: `rdma_write`, `rdma_send`, etc.

### IB/RDMA Tests (Hardware) — Real Traffic

Runs real RDMA traffic between two servers with Vulcano NICs.

```bash
# Basic test (4 QPs, ~2 minutes)
~/dev-notes/pensando-sw/scripts/run-ib-test.sh smc1-smc2 --qp 4

# Stress test (MSN window validation, ~5 minutes)
~/dev-notes/pensando-sw/scripts/run-ib-test.sh smc1-smc2 --qp 1 --max-msg-size 4M --direction bi --iter 2000

# Full benchmark with Excel output (~15 minutes)
~/dev-notes/pensando-sw/scripts/run-ib-test.sh smc1-smc2 --max-qp 16 --direction both --write-mode both --xlsx
```

**ALWAYS run IB tests inside tmux.** Tests take 45-60+ minutes for comprehensive runs.

---

## 10. Firmware Update & Deployment <a name="10-firmware-deployment"></a>

### Standard Workflow

```
  Build (Docker)         Copy (scp)           Update (nicctl)
  ┌──────────┐          ┌─────────┐          ┌─────────────┐
  │ make -f  │  ──tar──►│  scp to │  ──tar──►│ nicctl      │
  │ Makefile │          │  host   │          │ update fw   │
  │ .build   │          │  /tmp/  │          │ reset card  │
  └──────────┘          └─────────┘          └─────────────┘
```

```bash
# 1. Build firmware (inside Docker)
make -f Makefile.build build-rudra-vulcano-hydra-ainic-fw

# 2. Copy to target host (from inside Docker or host)
scp /sw/ainic_fw_vulcano.tar ubuntu@<HOST_IP>:/tmp/

# 3. On the target host:
sudo nicctl update firmware -i /tmp/ainic_fw_vulcano.tar
sudo nicctl reset card --all

# 4. Wait ~30 seconds, then verify:
sudo nicctl show card
sudo nicctl show version
```

### nicctl Quick Reference

```bash
nicctl show card              # Card status (should show "healthy")
nicctl show card -j           # JSON output
nicctl show version           # Firmware version
nicctl show port              # Port status (link up/down)
nicctl reset card --all       # Reset all cards
nicctl update firmware -i <tar>  # Update firmware
```

### Recovery (When Cards Don't Come Up)

```bash
# Automated recovery
~/dev-notes/pensando-sw/scripts/recovery-after-fw-update.sh smc1

# Manual steps:
# 1. Check version on Vulcano consoles
# 2. Reboot via SuC console (NEVER directly on Vulcano!)
# 3. Reboot host
# 4. Wait and verify
```

**CRITICAL:** Never reboot the Vulcano console directly. Always reboot through the SuC (Service & Update Controller) using `kernel reboot`.

---

## 11. Hardware Lab & Setups <a name="11-hardware-lab"></a>

### Lab Topology Overview

```
                         ┌───────────────────┐
                         │   Spine Switch     │
                         │   (800G fabric)    │
                         └───────┬───────────┘
                    ┌────────────┼────────────┐
                    │            │            │
              ┌─────▼─────┐ ┌───▼─────┐ ┌───▼─────┐
              │  Leaf 1   │ │ Leaf 2  │ │  Micas  │
              │ (Arista)  │ │(Arista) │ │ (ToR)   │
              └─────┬─────┘ └───┬─────┘ └───┬─────┘
                    │           │            │
           ┌───────┼──┐   ┌───┼──────┐  ┌──┼───────┐
           │       │  │   │   │      │  │  │       │
         Waco5  Waco6 │ Waco7 Waco8  │ SMC1     SMC2
        (8 NICs each) │(8 NICs each) │(8 NICs) (8 NICs)
                      │              │
                    GT1            GT4
                   (8 NICs)     (8 NICs)
```

### Setup Quick Reference

| Setup | IP | NICs | Switch | Primary Use |
|---|---|---|---|---|
| **SMC1** | 10.30.75.198 | 8 (ai0-ai7) | Micas 10.30.75.77 | Dev/test (most used) |
| **SMC2** | 10.30.75.204 | 8 (ai0-ai7) | Micas | Dev/test peer |
| **Waco5** | 10.30.64.25 | 8 | Arista Leaf1 | Arista topology |
| **Waco6** | 10.30.64.26 | 8 | Arista Leaf1 | Arista topology |
| **GT1** | 10.30.69.101 | 8 | 800G Leaf-Spine | 800G testing |

### Access

```bash
# SSH to server
ssh ubuntu@10.30.75.198     # SMC1 (password: amd123)

# Console access (via console manager)
~/dev-notes/pensando-sw/scripts/console-mgr.py --setup smc1 --console vulcano --all version

# Switch access
ssh admin@10.30.75.77       # Micas switch (password: Micas123)
ssh admin@10.30.64.201      # Arista Leaf1 (password: Gr33nTr33s)
```

---

## 12. Debugging & Diagnostics <a name="12-debugging"></a>

### On the Host

```bash
# Check card health
sudo nicctl show card
sudo nicctl show card -j         # JSON for parsing

# Check firmware version
sudo nicctl show version

# Check port status
sudo nicctl show port

# Check PCIe
lspci | grep -i pensando

# Check RDMA devices
ibv_devices
ibstat
```

### On the NIC Console (Vulcano)

Access via: `~/dev-notes/pensando-sw/scripts/console-mgr.py --setup smc1 --console vulcano --nic ai0 --cmd "show version"`

### Log Files (During Simulation / DOL)

| Log | Location | What to Look For |
|---|---|---|
| Model output | `/sw/nic/model.log` | Packet processing, table hits |
| PDS Core App | `/var/log/pensando/pds-core-app.log` | "Done initializing pdsagent" |
| DP App | `/var/log/pensando/dp-app.log` | "Pipeline initialization complete" |
| NicMgr | `/obfl/nicmgr.log` | QP state transitions, admin cmds |
| GTest | `hydra_gtest.log` | Test pass/fail, assertion details |
| DOL | `/sw/nic/dol.log` | DOL test results |

### Common Debug Patterns

**Test failing? Check this order:**
1. **Build clean?** Did you `make pull-assets` after switching branches?
2. **Right ASIC?** Vulcano and Salina have different binaries
3. **Context blocks correct?** Check SQCB/RQCB initialization in nicmgr logs
4. **P4 table miss?** Check model.log for table lookup failures
5. **DMA error?** Check for DMA completion errors in model output

---

## 13. Day-to-Day Workflow <a name="13-daily-workflow"></a>

### Typical Development Cycle

```
 1. Edit Code          2. Build             3. Test            4. Deploy
 ┌──────────┐        ┌──────────┐        ┌──────────┐       ┌──────────┐
 │ Edit P4  │        │ Build in │        │ Run      │       │ Build FW │
 │ or C     │  ───►  │ Docker   │  ───►  │ GTest or │ ───►  │ Deploy   │
 │ source   │        │ (incr.)  │        │ DOL      │       │ to HW    │
 └──────────┘        └──────────┘        └──────────┘       └──────────┘
     │                                        │                   │
     │        ┌─────── Fix & Repeat ──────────┘                   │
     │        │                                                    │
     ▼        ▼                                                    ▼
  Fast loop: Edit → Incremental Build → GTest (~15 min total)
  Full loop: Edit → Full Build → DOL → FW → Deploy → IB Test (~2-3 hours)
```

### Branch Workflow

```bash
# Start from latest master
git checkout master
git pull
git submodule update --init --recursive

# Create feature branch
git checkout -b my-feature-branch

# Make changes, build, test
# ...

# Commit (don't push without review)
git add <specific files>
git commit -m "Description of change"
```

### Quick Reference — "I want to..."

| Goal | Command |
|---|---|
| Build & run unit tests | `make -f Makefile.build build-rudra-vulcano-hydra-gtest` then `run_ionic_gtest.sh` |
| Build & run integration tests | `make -f Makefile.build build-rudra-vulcano-hydra-sw-emu` then `rundol.sh` |
| Deploy to hardware | `make -f Makefile.build build-rudra-vulcano-hydra-ainic-fw` then `scp` + `nicctl` |
| Check if my change compiles | `make -C nic PIPELINE=rudra P4_PROGRAM=hydra ARCH=x86_64 ASIC=vulcano package` |
| Run real RDMA test | `~/dev-notes/pensando-sw/scripts/run-ib-test.sh smc1-smc2 --qp 4` |
| Clean everything | `make clean && make -f Makefile.ainic clean` (inside Docker) |

---

## 14. Common Pitfalls <a name="14-common-pitfalls"></a>

### Build Issues

| Problem | Cause | Fix |
|---|---|---|
| "No such file or directory" during build | Missing submodules | `git submodule update --init --recursive` (outside Docker) |
| Build picks up old binaries | Stale Docker container | Clean up containers, relaunch Docker |
| "asset not found" errors | Missing prebuilt deps | `make pull-assets` inside Docker |
| Build fails after branch switch | Old artifacts | `make clean && make -f Makefile.ainic clean`, then rebuild |
| Permission denied on build dirs | Root-owned files from Docker | Clean inside Docker, not from host |

### Testing Issues

| Problem | Cause | Fix |
|---|---|---|
| GTest binary not found | Wrong build target | Use `build-rudra-vulcano-hydra-gtest`, not `x86-dol` |
| DOL "pipeline init failed" | Wrong build target | Use `build-rudra-vulcano-hydra-sw-emu` for DOL |
| Tests hang forever | Missing `sudo` | GTests need `sudo` for QEMU |
| IB test connection timeout | Cards not initialized | Run bringup script, check `nicctl show card` |

### Firmware Issues

| Problem | Cause | Fix |
|---|---|---|
| Cards don't come up after update | FW mismatch or boot issue | Run `recovery-after-fw-update.sh` |
| `nicctl show card` shows no cards | PCIe issue or crashed FW | Reboot host, check PCIe |
| Wrong FW version after update | Didn't reset cards | `sudo nicctl reset card --all` |

### General

- **Never build outside Docker** — the build system depends on Docker-specific paths and tools
- **Never reboot Vulcano directly** — always go through SuC (`kernel reboot`)
- **Always use tmux** — builds and tests are long, SSH drops are common
- **Always `pull-assets` after branching** — different branches may need different prebuilt dependencies

---

## 15. Key Contacts & Resources <a name="15-resources"></a>

### Documentation Locations

| Resource | Location |
|---|---|
| Dev-notes (complete reference) | `~/dev-notes/pensando-sw/` |
| Hardware setup details | `~/dev-notes/pensando-sw/hardware/vulcano/` |
| Automation scripts | `~/dev-notes/pensando-sw/scripts/` |
| IB testing guide | `~/dev-notes/pensando-sw/ib-testing-guide.md` |
| Quick start | `~/dev-notes/pensando-sw/QUICKSTART.md` |
| This document | `~/dev-notes/pensando-sw/ONBOARDING-MAP.md` |

### Useful Automation Scripts

| Script | Purpose |
|---|---|
| `console-mgr.py` | Manage 96 console connections across all setups |
| `run-ib-test.sh` | IB/RDMA test wrapper with presets |
| `update-firmware.sh` | Automated firmware deployment |
| `recovery-after-fw-update.sh` | Recovery when cards don't come up |
| `build-hydra-vulcano-gtest.sh` | One-command GTest build (tmux + docker + build) |
| `build-hydra-vulcano-dol.sh` | One-command DOL build |
| `run-hydra-gtest.sh` | GTest run helper (build, test, status) |
| `run-hydra-dol.sh` | DOL run helper |

### Glossary

| Term | Meaning |
|---|---|
| ASIC | Application-Specific Integrated Circuit (our NIC chip) |
| BTH | Base Transport Header (RoCE packet header) |
| CB | Context Block (QP state stored in NIC memory) |
| DCQCN | Data Center QCN (congestion control protocol) |
| DOL | Data-plane Offload Library (integration test framework) |
| DMA | Direct Memory Access |
| EQ | Event Queue |
| FEC | Forward Error Correction (link-level error recovery) |
| GRH | Global Route Header |
| LIF | Logical Interface (virtual NIC instance) |
| MR | Memory Region (registered host memory for RDMA) |
| MSN | Message Sequence Number |
| NAK | Negative Acknowledgment |
| NicMgr | NIC Manager (management daemon on ARM cores) |
| P4 | Programming Protocol-independent Packet Processors |
| P4+ | Pensando extensions to P4 for stateful processing |
| PD | Protection Domain |
| PSN | Packet Sequence Number |
| QP | Queue Pair (RDMA communication endpoint) |
| RCCL | ROCm Communication Collective Library |
| RNR | Receiver Not Ready |
| RoCE | RDMA over Converged Ethernet |
| RQCB | Receive Queue Context Block |
| SACK | Selective Acknowledgment |
| SerDes | Serializer/Deserializer (physical layer) |
| SQCB | Send Queue Context Block |
| SuC | Service & Update Controller (management processor) |
| WQE | Work Queue Entry |

---

*"The best way to learn is to build something, break it, and figure out why." — Start with GTests, graduate to DOL, then deploy to hardware.*
