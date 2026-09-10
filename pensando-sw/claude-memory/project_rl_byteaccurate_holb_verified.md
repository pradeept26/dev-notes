---
name: RL byte-accurate metering + tawk fix — HOLB verified on a-119 (kenya perf-3/4)
description: On the a-119 private build with byte-accurate LLC-meter RL, the working HOLB-recovery config is window-lg2 10 + rate 195G/port (NOT the old 191.5G/window-4 which over-throttles and stalls QPs); plus the a-119 perftest puec->mrc sysfs gotcha
type: project
originSessionId: 1418ad7a-e393-49d8-aa61-76d2bde9f02b
---
RL (LLC atomic meter) HOLB recovery verified on kenya perf-3/perf-4, a-119 private build (`1.130.0-a-119-20-g99c882a7c0d-dirty`, tawk PIC_RL fix + byte-accurate metering), 4×200G, path-1, 9 QP, unidirectional write:
- Baseline (RL off): **547.65 Gbps** (HOLB-degraded)
- RL 195G/port, window-lg2 10, burst 1MB: **765.76 Gbps** (+40% recovery, near ~800G unidir line rate)

**Why:** The byte-accurate metering change (meta_roce_tx_s6.p4) charges full WIRE bytes (payload + meta_roce_hdr + ah/outer Eth-IP-UDP + ICRC) instead of payload-only packet_len.

**Tuning (critical, differs from the old a-106 flow):**
- **window-lg2 must be 10 (~1µs), NOT 4 (~14ns).** window-4 makes throttling bursty → QP stalls (`requester RX error-disabled 0xc`, `ack_msn not advancing`, `spec_failure rollback`, perftest `Failed to complete run_iter_bw scnt≫ccnt`).
- **rate must be ~195G/port, NOT 191.5G.** With wire-byte accounting, 191G over-throttles → same stall. 195G works; 300G = no throttle (=baseline, proves it's over-throttle not a metering bug).
- burst 1MB (`--burst-bytes 1048576`) helps vs 256000.

**Perftest gotcha (a-119):** installed `/usr/bin/ib_write_bw` (and all 1.125-era bundles on the box) read `/sys/class/infiniband/<dev>/puec_nports`, but the a-119 driver renamed it to `mrc_nports` (rename puec->mrc commit). Perftest sees 0 planes → collapses to 1 plane (176 Gbps, MTU 1024). Quick fix: binary-patch a copy — `python3 replace b"puec_nports"->b"mrc_nports\x00"` (null truncates path). Proper fix: use a 1.130/a-119 perftest. After patch: multiplane spreads, MTU 4096.

**Bringup gotchas:** m4setup leaves the RDMA base netdev `enp195s0f3` DOWN (must `ifconfig enp195s0f3 19.0.0.$LO/24 mtu 9000 up` — RoCE port PORT_ACTIVE follows it) and the multiplane line commented out (must `echo 4 > /sys/class/infiniband/rocep195s0f3/mrc_nports` + `nicctl update multiplane`). Reboots reset CPU governor (set performance) + hugepages.
