---
name: mputrace
description: "Capture and decode MPU traces (PHV debug) on Vulcano and Salina NICs. Configures mputrace on the NIC, runs a test, dumps and decodes traces using vultrace (Vulcano) or saltrace (Salina). Use when user says capture phv, mputrace, trace pipeline, debug phv, capture trace, decode trace."
---

# MPU Trace Skill

Capture PHV-level pipeline traces on Vulcano/Salina NICs for deep datapath debugging.

## Usage

```
/mputrace <node> [options]
```

## Arguments

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| node | yes | — | Target host IP or name |
| --asic | no | vulcano | `vulcano` or `salina` |
| --card-uuid | no | auto | NIC card UUID |
| --workspace | no | current | Build workspace with matching firmware |
| --stages | no | `.*` | Stage regex filter |
| --output | no | /tmp | Output directory for trace files |

## Prerequisites

- Firmware with `debug_trace` instrumentation in the paths to trace:
  ```p4
  p.p4_intr_global.debug_trace = 1;
  __trace(1);
  ```
- Build workspace with matching firmware build (for decode)
- `mputrace` binary on the target host (installed with firmware)

## Phase 1: Configure Trace

### 1a. Create mputrace config

```json
{
  "instances": [{
    "pipeline": "uxdma.*",
    "stage": ".*",
    "mpu": ".*",
    "control": { "trace": true, "phv-debug": true, "phv-error": false },
    "capture": { "key-data": true, "instructions": false },
    "settings": { "trace-size": "128", "wrap": true }
  }]
}
```

**Config options:**
- `trace: true, phv-debug: true` → capture only PHVs with `debug_trace=1` (selective)
- `trace: false, phv-debug: false` → capture ALL PHVs (noisy, fills buffer fast)
- `key-data: true` → capture K-vector and D-vector (CB state)
- `instructions: false` → skip per-instruction capture (saves space)
- `trace-size: 128` → trace buffer size in KB

### 1b. Reset and configure on target

```bash
ssh <node> '
  source /etc/profile.d/amd_ainic_user_profile_update.sh
  export PAL_CARD_UUID=<card-uuid>
  mputrace -use-full-trace-region reset_mpu
  mputrace -use-full-trace-region -V 5 conf /tmp/mputrace.json
'
```

## Phase 2: Run Test

Run the workload that generates the PHVs you want to capture.
The trace buffer captures in a ring — older entries are overwritten.
Keep the test short to avoid overflow.

## Phase 3: Dump Trace

```bash
ssh <node> '
  export PAL_CARD_UUID=<card-uuid>
  mputrace -use-full-trace-region -V 5 dump /tmp/mputrace.bin
'
```

Verify trace has data:
```bash
hexdump mputrace.bin -e '64/1 "%02X" "\n"' | grep C0DE411
```

## Phase 4: Decode

### Vulcano

Generate symbols (one-time per build, inside Docker):
```bash
cd /sw/nic
ARCH=riscv P4_PROGRAM=hydra python3 sdk/platform/vultrace/vultrace.py gen_syms \
  --sym_file vultrace.syms --pipeline=rudra --asic=vulcano
```

Decode (inside Docker):
```bash
cd /sw/nic
ARCH=riscv P4_PROGRAM=hydra python3 sdk/platform/vultrace/vultrace.py decode_mpu \
  mputrace.bin \
  --load=conf/gen/p4_init_cfg_gen/mpu_prog_info.json \
  --sym=vultrace.syms > mputrace.decode
```

### Salina

Generate symbols (inside Docker):
```bash
cd /sw/nic
ARCH=aarch64 P4_PROGRAM=pulsar ./sdk/platform/saltrace/saltrace.py gen_syms \
  --sym_file saltrace.syms --pipeline=rudra
```

Decode (inside Docker):
```bash
cd /sw/nic
./sdk/platform/saltrace/saltrace.py decode_mpu mputrace.bin \
  --load=conf/gen/p4_init_cfg_gen/mpu_prog_info.json \
  --sym=saltrace.syms > mputrace.decode
```

## Phase 5: Analyze

### Find specific PHVs

```bash
# Find req_tx S0 entries:
grep -n 'PROGRAM.*req_tx_s0' mputrace.decode

# Find resp_rx S0 entries:
grep -n 'PROGRAM.*resp_rx_s0' mputrace.decode
```

### Extract PHV fields

The decoded output shows per-stage PHV fields. Key fields to look for:
- `phv_timestamp_capture` — PHV creation timestamp
- `meta_roce_bth.*` — BTH header fields (opcode, path_id, dst_qp)
- `meta_roce_hdr.meth.*` — METH fields (msn, posn, fsn, tag)
- `meta_roce_hdr.reth.*` — RETH fields (va, rkey, length)
- `window_avail_bitmap` — SQCB5 credit bitmap (if alias active)

### Build timing table

Sort entries by `phv_timestamp_capture`, compute deltas between stages:
```
Stage     Program                    Ticks    ~ns
S0→S1     req_tx_sqcb_process          xxx     xxx
S1→S2     req_tx_sqwqe_process         xxx     xxx
...
```

Vulcano clock: check ASIC spec for tick-to-ns conversion.

## Notes

- Trace buffer is a ring — wraps if test runs too long
- `debug_trace` instrumentation adds ~2 instructions to S0 — negligible overhead
- For selective capture, gate on specific conditions (e.g., `if (msn == 2)`)
- Generate symbols AFTER the build (needs build artifacts in `rudra/build/`)
- Symbols are large (~269MB with PHV info) — reuse across sessions
- `mputrace reset_mpu` clears the trace buffer — run before each capture
