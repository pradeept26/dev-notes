---
name: SMC testbed GPUs + dmabuf limitation
description: SMC (smc1/smc2) has 8x MI300X GPUs; GPUDirect dmabuf fails on its kernel 5.15 — use peer-mem instead
type: reference
originSessionId: 89f159fb-8d11-488b-bb5c-323b690ec310
---
SMC testbed (smc1 `10.30.75.198`, smc2 `10.30.75.204`, root/docker) is **GPU-capable**: 8× **AMD Instinct MI300X** per node + ROCm at `/opt/rocm`. NIC/GPU pairing e.g. `benic3p1` (card BDF `0000:43:00.0`) ↔ `--use_rocm=2`. Profile is **1×400G** (bidir ceiling ~800 Gb/s → ~760 line rate, roughly half of an 800G port).

**dmabuf GPUDirect is broken on SMC** — `ib_write_bw --use_rocm_dmabuf` fails with *"Failed to init memory"*. Confirmed on BOTH NIC builds (1.130.2-a-8 driver 26.06.28.001 AND 1.130.0-a-55 driver 26.07.11.001), so the cause is the **host kernel `5.15.0-185`**, not the NIC FW/driver.

**Why:** kernel 5.15 lacks working dmabuf MR import for this RDMA stack. **How to apply:** for any GPU-memory RDMA test on SMC, use the peer-memory path (`--use_rocm=<N>` *without* `--use_rocm_dmabuf`); it works fine (line-rate GPUDirect). To exercise the dmabuf datapath you'd need a newer-kernel host (e.g. evt2).

Stock `/usr/bin/ib_write_bw` has **no** `--use_rocm` support — a ROCm-enabled perftest must be compiled from the FW bundle's `drivers-linux/perftest` (`./autogen.sh && ./configure --with-rocm=/opt/rocm --enable-rocm --enable-rocm-dmabuf`; needs `libtool`, which is not preinstalled). Compile skill: `~/systest-agentq/projects/ainic/mrc/skills/compile-perftest.md`.
