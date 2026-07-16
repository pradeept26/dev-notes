---
name: analyze-latency
description: End-to-end RDMA latency analysis using MPU trace. Supports single-node PCS-loopback (isolates NIC pipeline) and 2-node mode (mputrace on both NICs, decomposes full RTT into initiator NIC + network + peer NIC). Configures mputrace, runs ib_write_lat, collects and decodes traces, then analyzes per-stage pipeline timing breakdown.
---

## Usage

```
/analyze-latency <node> [peer] [options]
```

**Mode selection:**
- One node → **loopback mode**: sets up macvlan namespaces with PCS port loopback on a single NIC
- Two nodes → **2-node mode**: mputrace on both NICs, decomposes full RTT

## Arguments

- `node` (required): Initiator node (client side of ib_write_lat)
- `peer` (optional): Responder node for 2-node mode. If omitted, uses loopback mode
- `--size <bytes>`: Message size (default: 24)
- `--iterations <n>`: Number of iterations (default: 5)
- `--workspace <path>`: Build workspace for decode (must have matching firmware build)
- `--stages <regex>`: Stages to trace (default: `.*` for all stages)
- `--packet <n>`: Which packet to analyze (default: 4th, to skip cache warmup)
- `--interface <name>`: Network interface (default: auto-discover from show_gid)
- `--device <name>`: RDMA device (default: auto-discover)

## Examples

```bash
# Single-node loopback (isolates NIC pipeline latency)
/analyze-latency ib_node1 --workspace /ws/pradeept/ws/usr/src/github.com/pensando/sw

# 2-node (full RTT decomposition: initiator NIC + network + peer NIC)
/analyze-latency ib_node1 ib_node2 --workspace /ws/pradeept/ws/usr/src/github.com/pensando/sw

# 2-node with options
/analyze-latency ib_node1 ib_node2 --size 4096 --iterations 10 --packet 8
```

## What It Does

### Loopback Mode (single node)

Performs an **external loopback** latency analysis using macvlan namespaces with **PCS port
loopback**. Packets traverse the full NIC path (UDMA → pDMA → PB → TFP → MAC → TID → PB → UDMA)
while keeping both req_tx and resp_rx on the same NIC for a single mputrace capture.

**Turnaround measures:** NIC-only pipeline time (no network, no remote NIC).

> **Loopback mode names (verify per build):** on 1.130.x hydra the port modes are
> `phy, pcs, xcvr-host-input, xcvr-host-output, xcvr-media-input, xcvr-media-output, none`.
> There is **no `mac` mode** — use `pcs` (loops at PCS, just below the MAC). True XRMAC "mac"
> loopback is only reachable via the `loopbackctl` devcmd with the ionic driver unloaded
> (`nic/rudra/src/hydra/nicmgr/tools/loopbackctl`).

### 2-Node Mode

Performs latency analysis between **two real servers** with mputrace captured on **both** NICs.
This lets us decompose the full RTT into measurable components:

- **Initiator NIC**: req_tx (outbound write) + resp_rx (inbound ACK)
- **Peer NIC**: resp_rx (inbound write) + req_tx (outbound ACK)
- **Network RTT**: derived by subtracting both NIC times from the E2E turnaround

Without both traces, the peer NIC processing is an opaque blob inside the turnaround.

See `~/.claude/docs/debugging/mputrace-workflow.md` (collection) and
`~/.claude/docs/debugging/mputrace-latency-analysis.md` (analysis methodology).

---

## Phase 1: Setup

### Common — discover NICs on both nodes

1. **Discover NIC on initiator** node:
   - Run `show_gid` to find RDMA device, interface, IP, GID index
   - Run `sudo nicctl show card` to get card UUID
   - Run `sudo nicctl show qos` to get port UUID
   - See `~/.claude/docs/debugging/nic-identification.md`

### Loopback mode only

2. **Enable port loopback (PCS)** on the port:
   ```bash
   nicctl update port -p <port_uuid> --loopback-mode pcs
   ```
   (`mac` is not a valid mode on 1.130.x hydra — see the note above.)

3. **Create macvlan namespaces**:
   ```bash
   ip netns add ns1 && ip netns add ns2
   ip link add macv1 link <interface> type macvlan mode bridge
   ip link add macv2 link <interface> type macvlan mode bridge
   ip link set macv1 netns ns1 && ip link set macv2 netns ns2
   ip -n ns1 addr add 10.0.0.1/24 dev macv1 && ip -n ns1 link set macv1 up
   ip -n ns2 addr add 10.0.0.2/24 dev macv2 && ip -n ns2 link set macv2 up
   ```

4. **Verify**: ping between namespaces, check GID indices for macvlan IPs in `show_gid`

### 2-node mode only

2. **Discover NIC on peer** (responder) node:
   - Run `show_gid` to find RDMA device, GID index, and IP
   - Run `sudo nicctl show card` to get peer card UUID
   - Record peer IP for the client connection

3. **Verify RDMA connectivity**:
   ```bash
   ping -c 3 <peer_ip>
   ```

---

## Phase 2: Collect Traces

### Create mputrace config (same on both nodes for 2-node mode)

5. **Create mputrace config** (`/tmp/mputrace_rdma.json`):
   ```json
   {
     "instances": [{
       "pipeline": "uxdma.*",
       "stage": "<stages>",
       "mpu": ".*",
       "control": { "trace": true, "phv-debug": true, "phv-error": false },
       "capture": { "key-data": true, "instructions": false },
       "settings": { "trace-size": "128", "wrap": true }
     }]
   }
   ```
   Note: `trace: true` and `phv-debug: true` require firmware instrumentation
   (`__trace(1)` and `p.p4_intr_global.debug_trace = 1` in S0 programs).
   If not instrumented, set both to `false` to trace all PHVs.

### Reset and configure mputrace

6. **On initiator**:
   ```bash
   source /etc/profile.d/amd_ainic_user_profile_update.sh
   export PAL_CARD_UUID=<initiator_card_uuid>
   mputrace -use-full-trace-region reset_mpu
   mputrace -use-full-trace-region -V 5 conf /tmp/mputrace_rdma.json
   ```

   **On peer (2-node mode only)**:
   ```bash
   source /etc/profile.d/amd_ainic_user_profile_update.sh
   export PAL_CARD_UUID=<peer_card_uuid>
   mputrace -use-full-trace-region reset_mpu
   mputrace -use-full-trace-region -V 5 conf /tmp/mputrace_rdma.json
   ```

### Run the latency test

7. **Loopback mode:**
   - Server: `ip netns exec ns2 numactl --cpunodebind=<numa> ib_write_lat -d <device> -i 1 -s <size> -n <iterations> -F -x <gid_idx_ns2> -p <port>`
   - Client: `ip netns exec ns1 numactl --cpunodebind=<numa> ib_write_lat -d <device> -i 1 -s <size> -n <iterations> -F -x <gid_idx_ns1> -p <port> 10.0.0.2`

   **2-node mode:**
   - Server (on peer): `ib_write_lat -d <device> -i 1 -s <size> -n <iterations> -F -x <gid_idx> -p <port>`
   - Client (on initiator): `ib_write_lat -d <device> -i 1 -s <size> -n <iterations> -F -x <gid_idx> -p <port> <peer_ip>`

   Record the app-reported latency.

   Notes (loopback mode):
   - **Separate netns are mandatory** — same-netns endpoints get delivered locally and firmware sets
     `ud_loopback=1` (P4 internal shortcut), so frames never reach the port/PCS loop.
   - `numactl --cpunodebind=<numa>` (the NIC's NUMA node) — `netdev:<name>` won't resolve inside a netns.
   - **GPU memory:** add `--use_rocm=<gpu>` (GPU paired to the NIC by PCIe locality) to BOTH ends.
     Needs a ROCm-enabled perftest — stock `/usr/bin/ib_write_lat` has none; use
     `/mnt/clusterfs/visampath/ib_write_lat` (v6.25).
   - **write-with-imm:** add `--write_with_imm` (SYMMETRIC — pass on BOTH server and client).
   - Wrap the perftest command in `stdbuf -oL` so the `local address: ... QPN 0x..` line flushes to the
     log during the run (needed to get `<qid>` for the verification in step 8).

8. **Verify the packet took the port/PCS path** (loopback mode only) — i.e. `ud_loopback=0`, not the
   firmware internal shortcut. Two ways:
   - **Ground truth (works even under host-tools↔FW version skew):**
     ```bash
     PAL_CARD_UUID=<card_uuid> eth_dbgtool rdma_qstate <lif> 3 <qid> | grep ud_loopback
     ```
     `qtype 3` = SQ; `<qid>` = perftest's local QPN (the `QPN 0x..` line — needs `stdbuf -oL`, step 7);
     `<lif>` = the NIC's internal RDMA lif (benic1p1 = 18; enumerate with `--active-qps` if unknown).
     Want `sqcb0.ud_loopback 0`. Stale/empty QPs read as `ud_loopback 1 / path_qid_base ffff` — ignore those.
     (`nicctl show rdma queue-pair --raw | grep loopback` also works, but returns "lif not found" when
     host-tools don't match the card FW.)
   - **Robust fallback (no lif/qid needed) — MAC frame counters:**
     ```bash
     nicctl show port statistics -p <port_uuid> | grep -E 'FRAMES_(TX|RX)_OK'   # before and after a run
     ```
     `TX_OK ≈ RX_OK` (equal, nonzero delta) → frames looped through the MAC/PCS; `≈0` → internal shortcut.

   If `ud_loopback = 1`, the firmware is bypassing TFP/MAC/TID (check you used **separate netns**) — the
   turnaround won't include those components.

### Dump traces

9. **Loopback mode** — dump on initiator:
   ```bash
   mputrace -use-full-trace-region -V 5 dump /tmp/mputrace.bin
   ```

   **2-node mode** — dump on BOTH nodes:
   ```bash
   # On initiator
   mputrace -use-full-trace-region -V 5 dump /tmp/mputrace_initiator.bin

   # On peer
   mputrace -use-full-trace-region -V 5 dump /tmp/mputrace_peer.bin
   ```

10. **Verify trace(s)** have data:
    ```bash
    hexdump <trace_file> -e '64/1 "%02X" "\n"' | grep C0DE411
    ```

---

## Phase 3: Decode

`saltrace.py` is pure Python — no Docker-only dependencies. It just needs the **build output dirs**
to exist, which are created during firmware build. Run from host or Docker.

11. **Copy trace binary(ies)** to the build workspace
    ```bash
    # Loopback
    scp <node>:/tmp/mputrace.bin <workspace>/nic/

    # 2-node
    scp <node>:/tmp/mputrace_initiator.bin <workspace>/nic/
    scp <peer>:/tmp/mputrace_peer.bin <workspace>/nic/
    ```

12. **Generate symbols** (one-time per build):
    ```bash
    cd <workspace>/nic
    ARCH=aarch64 P4_PROGRAM=pulsar ./sdk/platform/saltrace/saltrace.py gen_syms \
      --sym_file saltrace.syms --pipeline=rudra
    ```

13. **Decode**:
    ```bash
    # Loopback — single decode
    ./sdk/platform/saltrace/saltrace.py decode_mpu mputrace.bin \
      --load=conf/gen/p4_init_cfg_gen/mpu_prog_info.json \
      --sym=saltrace.syms > mputrace.decode

    # 2-node — decode both
    ./sdk/platform/saltrace/saltrace.py decode_mpu mputrace_initiator.bin \
      --load=conf/gen/p4_init_cfg_gen/mpu_prog_info.json \
      --sym=saltrace.syms > mputrace_initiator.decode

    ./sdk/platform/saltrace/saltrace.py decode_mpu mputrace_peer.bin \
      --load=conf/gen/p4_init_cfg_gen/mpu_prog_info.json \
      --sym=saltrace.syms > mputrace_peer.decode
    ```

---

## Phase 4: Analyze

### Loopback mode

14. **Find the Nth packet** (default: 4th):
    - req_tx: `grep -n 'PROGRAM.*req_tx_s1_sqwqe' mputrace.decode`
    - resp_rx: `grep -n 'PROGRAM.*resp_rx_s2' mputrace.decode`

15. **Extract `phv_timestamp_capture`** for req_tx (a few lines above the match)

16. **Find all req_tx stages** for that PHV timestamp

17. **Find the corresponding resp_rx**: search for the 4th resp_rx S2, extract its own `phv_timestamp_capture`, find all resp_rx stages

18. **Build the timing table**: sort by timestamp, compute deltas
    - Convert ticks to ns (Salina: 1.1 GHz, 1 tick = 0.909 ns)
    - The turnaround = resp_rx S0 timestamp − req_tx S7 timestamp

### 2-node mode

14. **Initiator trace** (`mputrace_initiator.decode`):
    The initiator NIC sees req_tx (outbound RDMA Write) and resp_rx (inbound ACK).
    - Find 4th req_tx: `grep -n 'PROGRAM.*req_tx_s1_sqwqe' mputrace_initiator.decode`
    - Find 4th resp_rx: `grep -n 'PROGRAM.*resp_rx_s2' mputrace_initiator.decode`
    - Extract `phv_timestamp_capture` for each, find all stages
    - **E2E turnaround** = initiator resp_rx S0 − initiator req_tx S7

15. **Peer trace** (`mputrace_peer.decode`):
    The peer NIC sees resp_rx (inbound RDMA Write) and req_tx (outbound ACK).
    - Find 4th resp_rx: `grep -n 'PROGRAM.*resp_rx_s2' mputrace_peer.decode`
    - Find 4th req_tx: `grep -n 'PROGRAM.*req_tx_s1' mputrace_peer.decode`
    - Extract `phv_timestamp_capture` for each, find all stages
    - **Peer NIC processing** = peer req_tx S7 − peer resp_rx S0

16. **Derive network transit time**:
    ```
    initiator_nic_time = (initiator req_tx S0→S7) + (initiator resp_rx S0→S7)
    peer_nic_time      = (peer resp_rx S0→S7) + (peer req_tx S0→S7)
    e2e_turnaround     = initiator resp_rx S0 − initiator req_tx S7
    network_rtt        = e2e_turnaround − peer_nic_time
    ```
    Note: `network_rtt` includes wire time + switch latency in both directions, plus any
    pDMA/PB time not captured in stage timestamps.

---

## Phase 5: Report

### Loopback mode report

```
Latency Analysis: <node> external loopback (<size>B, <iterations> iterations)
═══════════════════════════════════════════════════════════════════════════════

App-reported: <typical> usec (min: <min>, max: <max>)
sqcb0.loopback: 0 (confirmed full TFP/MAC/TID path)

Half-RTT breakdown:
  ┌──────────┬───────────────┬──────────────────┬──────────────┬──────────────┐
  │ Host→NIC │  req_tx S0→S7 │  NIC turnaround  │ resp_rx S0→S7│  NIC→Host    │
  │   ???    │    xxx ns      │     xxx ns        │   xxx ns     │    ???       │
  └──────────┴───────────────┴──────────────────┴──────────────┴──────────────┘

  NIC measured:    xxxx ns (xx%)
  Host unmeasured: xxxx ns (xx%)

req_tx per-stage:
  Stage     Program                              Ticks    ~ns     %
  ────────  ───────────────────────────────────  ──────  ──────  ────
  PHV→S0    ...                                    xxx     xxx   xx%
  S0→S1     ...                                    xxx     xxx   xx%
  ...
  TOTAL     PHV → S7                               xxx     xxx

NIC turnaround (req_tx S7 → resp_rx S0):
  xxx ticks (xxx ns) — includes S7 exec + pDMA + PB + TFP + MAC + TID + PB

resp_rx per-stage:
  Stage     Program                              Ticks    ~ns     %
  ────────  ───────────────────────────────────  ──────  ──────  ────
  S0→S2     ...                                    xxx     xxx   xx%
  ...
  TOTAL     S0 → S7                                xxx     xxx
```

### 2-node mode report

```
Latency Analysis: <node> → <peer> 2-node (<size>B, <iterations> iterations)
═══════════════════════════════════════════════════════════════════════════════

App-reported: X.XX usec (min: X.XX, max: X.XX)

Full RTT breakdown (both NICs instrumented):
  ┌──────────┬────────────────┬─────────┬────────────────┬─────────┬────────────────┬──────────┐
  │ Host→NIC │ init req_tx    │ Network │ peer resp_rx + │ Network │ init resp_rx   │ NIC→Host │
  │          │ S0→S7          │ →       │ req_tx (ACK)   │ ←       │ S0→S7          │          │
  │   ???    │   xxx ns       │ xxx ns  │    xxx ns       │ xxx ns  │   xxx ns       │   ???    │
  └──────────┴────────────────┴─────────┴────────────────┴─────────┴────────────────┴──────────┘

  Initiator NIC pipeline: xxxx ns
  Peer NIC pipeline:      xxxx ns
  Network RTT:            xxxx ns (derived)
  Host overhead:          xxxx ns (unmeasured)

INITIATOR req_tx per-stage (outbound RDMA Write):
  Stage     Program                              Ticks    ~ns     %
  ────────  ───────────────────────────────────  ──────  ──────  ────
  PHV→S0    ...                                    xxx     xxx   xx%
  S0→S1     ...                                    xxx     xxx   xx%
  ...
  TOTAL     PHV → S7                               xxx     xxx

PEER resp_rx per-stage (inbound RDMA Write):
  Stage     Program                              Ticks    ~ns     %
  ────────  ───────────────────────────────────  ──────  ──────  ────
  S0→S2     ...                                    xxx     xxx   xx%
  ...
  TOTAL     S0 → S7                                xxx     xxx

PEER req_tx per-stage (outbound ACK):
  Stage     Program                              Ticks    ~ns     %
  ────────  ───────────────────────────────────  ──────  ──────  ────
  ...
  TOTAL     PHV → S7                               xxx     xxx

INITIATOR resp_rx per-stage (inbound ACK):
  Stage     Program                              Ticks    ~ns     %
  ────────  ───────────────────────────────────  ──────  ──────  ────
  ...
  TOTAL     S0 → S7                                xxx     xxx
```

---

## Phase 6: Cleanup

### Loopback mode only

20. **Remove namespaces and disable port loopback**:
    ```bash
    ip netns del ns1 && ip netns del ns2
    nicctl update port -p <port_uuid> --loopback-mode none
    ```

### 2-node mode

20. **No cleanup needed** — no namespaces or loopback mode changes were made.

---

## Prerequisites

- Node(s) accessible via SSH
- Build workspace with matching firmware (for decode) — can run on host or in Docker
- For selective tracing: firmware with `debug_trace` + `__trace(1)` in S0 programs
- **2-node mode**: RDMA connectivity between the two nodes (link up, IPs configured, GIDs visible)

## Reference Documentation

- Collection and decode: `~/.claude/docs/debugging/mputrace-workflow.md`
- Analysis methodology: `~/.claude/docs/debugging/mputrace-latency-analysis.md`
- NIC identification: `~/.claude/docs/debugging/nic-identification.md`
- Example analysis with results: `~/.claude/docs/debugging/salina-latency-analysis.md`
