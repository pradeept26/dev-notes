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

**UPDATE 2026-09-17 — ToT+scatter build (`1.130.0-a-129-30`, Gaurav meter_rl_llc / PR #119731) flips the window/burst tuning:** on the scatter-fix build the standardized config is **rate 199G / burst 200000 / window-lg2 4 / max-ports 4** (Vishwas's cfg), and it reaches line rate. Directly measured: 512-QP RCN-off bidir = **1510 Gbps with 200K/win4** vs only **1485 with 256K/win10** (+25G). So win4 is now BETTER than win10 — opposite of the a-119 finding above. Reason: the scatter fix distributes displaced QPs so smaller burst + tighter window catches per-port microbursts sooner without over-throttling. Full HOLB validation (1a path-4 sweep, 1b path-1 proof, 1c live port-shut) passed on ToT — RL recovers HOLB (9QP path-1 +24–45%; shut-2 survivor skew +24–25%). Report: srv6.pensando.io/systest/agentq/rl-scatter-holb-pradeept/. RL lif on 4×200G a-129 = **hw_id 1** (not 18). Live port-shut = `nicctl update port -p <uuid> -a down` (netdev `ip link down` does NOT drop the RDMA plane). `--run_infinitely -D 5` gives per-interval BW (not cumulative). Bottom line: window/burst tuning is BUILD-dependent — verify per build.

**UPDATE 2026-09-18 — 2×400G HOLB validated on same ToT+scatter build.** Reflashed `meta-roce-2x400G-4` (FW upgrade + profile switch = flash A → `nicctl reset card --all` → flash alt partition [both must match] → `nicctl update card profile -p meta-roce-2x400G-4 -i <fw>` → **reboot REQUIRED**). RL cfg for 2×400G = **399.5G/port (99.5% of 400G, the 2×400 analogue of 199G@4×200) / burst 300000 / win4 / max-ports 2** — user-tuned, reaches line rate for BOTH uni (~772 vs 777 off) and bidir (~1518). 200K under-reached uni (~755), 256K better (~765), 300K best. Result: **RL recovers 2-port HOLB to line rate** — path-1 no-RCN q7/q9 RL-off 1327/1391 → RL-on **1530** (+15/+10%); RCN ω7 milder (self-heals to ~1490, RL adds less); **path-4 (2 paths/port = non-flat exclusion branch) self-balances, RL idle**; uni low-QP = demand-starved (floor RL can't raise). Report: srv6.pensando.io/systest/agentq/rl-scatter-holb-2x400-pradeept/. Harness /tmp/holb2x/ (lib2x.sh, run_1a_2x.sh, run_1b_2x.sh). 2×400G bringup = `/root/gaurav/m2fix.sh <2|1>`, mrc_nports=2, 2 planes enp196/197s0.

**GOTCHA — sw-dev9 host disk:** root LV `/` (437G) fills to 100% from **deleted-but-open files** (another user's runaway log held ~284G; `du /`=126G vs `df`=417G used → find via `sudo lsof +L1`). Docker is on a SEPARATE disk `/local` (=/dev/sda1, docker data-root `/local/docker`), NOT the root fs. When `/` hits true 0, the Claude Bash tool breaks (can't mkdir temp) — but nohup-detached test runs + incremental CSV writes survive (zero data loss). Also: **`pkill -f <pattern>` self-matches the current Bash command line and kills its own shell** → use PID-based `kill`/`kill -0` for harness process control, not `pkill -f run_*.sh`.
