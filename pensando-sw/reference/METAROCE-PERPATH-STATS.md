# MetaRoCE Per-Path Diagnostic Counters (Meta G3) — Dev Note

**Status:** FW/nicmgr handler implemented + HW-validated. Branch pushed to fork. Paused
pending driver-team (Nikhil) response on the netlink rendering question. NOT merged.

**Date:** 2026-06-25
**Branch:** `metaroce-perpath-stats` (pushed to `pradeept26` fork, NOT origin)
**Platform validated:** Vulcano / hydra, FW `1.130.0-a-32` + private build, SMC testbed (smc1/smc2)

---

## What this is

Meta "Standardization of Diagnostic Counters" (G3) asks for per-QP **per-path** RDMA
counters. We implemented the FW side so a QP's multipath stats (one block per active path:
RTT buckets, min/max RTT, acks/pkts/drops/dup, cc_add/mul, cnp, ooo, sacks, ecns,
rto_retx, sack_retx, cwnd_retry, path_inactive/disabled, oport changes, retry_ring_db, …)
can be read out.

### Design — Option 2 (reuse `QP_STATS_VALS`)
Rather than a new admin opcode, we reuse the existing `QP_STATS_VALS` (opcode 18). The
driver signals "give me per-path" by supplying a buffer **>4 KB**. When FW sees that, it
appends, in a **single edma**:

```
[ QP-level stats block ][ path header (num_paths, path_stat_size) ][ path block 0 ][ block 1 ]...
```

- `path_stat_size = 116` bytes/block. `num_paths` from `sqcb1.max_paths`.
- Per-path CB address: `path_stats_addr(qid) = g_path_stats_base + qid*128`
  (path CB stride 128B; `path_qid_base` from `sqcb0`).
- **Single edma is deliberate** — it bounds nicmgr work per command so the heartbeat/
  watchdog can't be starved. This was the main design risk and the soak tests target it.
- ≤4 KB request → legacy QP-only behavior (no header), full back-compat.
- FW caps `num_paths` to what fits the driver buffer (and edma scratch: 32 KB HW / 4 KB sim).

### Capacities
- `max_stats_buf_size` advertised in identify = 16384 (hydra). Cap bit
  `IONIC_LIF_RDMA_STAT_QP_PATH = BIT(2)` in `stats_type` (observed 0x7 on HW).
- Max paths/QP = **64** (`sqcb1.max_paths` ceiling; nicctl range goes to 80 but HW caps 64).
- FW path-CB table = **8192** entries → `qp_count × path_count ≤ 8192`.

---

## Code map

### FW / nicmgr (committed, branch `metaroce-perpath-stats`)
- `52b1bf7` **(WIP — needs de-WIP/squash before PR)** — the handler:
  - `nic/rudra/src/hydra/nicmgr/plugin/rdma/admincmd_handler.c` — VALS handler
    `eth_rdma_impl_aq_qp_stats_vals_hdlr` (path-block assembly, single edmaq_copy).
  - `…/admincmd_handler.h` — per-path response structs / layout.
  - `…/rdma/init.c`, `nic/sdk/rtos-shared/src/lib/nicmgr/rdma/devcmd_handler.c`,
    `…/rdma/mgr.h` — wiring + identify advertisement.
  - `platform/drivers/common/ionic_if.h` — in-tree ABI (cap bit + max_stats_buf_size).
- `69a6d33` — gtest (`nic/rudra/test/hydra/gtest/aq/qp_path_stats_test.cc`, both tests pass),
  e2e driver bits, `main.cc` multipath enable (PATH_QID_START 3→0 + puec override under SIM).

`nic/` working tree is otherwise clean. Untracked `nic/conf/*`, `nic/etc/` are build artifacts.

### Driver (UNcommitted — submodule `platform/drivers/linux-ionic`, this is Nikhil's repo)
- `eth/ionic/ionic_if.h` — driver-side ABI (QP_PATH cap bit, `max_stats_buf_size`
  carved from `rsvd1`). **Needs committing in the driver repo** for the driver to consume it.
- `rdma/drv/ionic/ionic_hw_stats.c` — **THROWAWAY** debugfs diagnostic node
  `qp_path_stats` (the HW trigger; DO NOT commit). `echo "<qpid> [len]" > node; cat node`.

---

## HW validation (all PASS) — via the throwaway debugfs node, NOT nicctl

nicctl reads HBM path CBs directly and **bypasses the VALS code**, so it can't validate the
new path. The debugfs node drives the real `QP_STATS_VALS` adminq → FW handler → edma path.

| Dimension | Result |
|---|---|
| Correctness/consistency | Σ per-path `rx_acks` == QP `req_rx_num_acks` exactly @ 8, 64, 2048 QPs (tiny live-traffic skew) |
| Header tracks config | `num_paths` == configured path count (1-block→64) every time |
| Path-inactive detect | unused path = sentinel `min_rtt=65535` + zero block |
| Max-path payload | 64-path dump = 64 valid blocks, ~7.7 KB within 16 KB buffer |
| Full-table addressing | 2048 QP × 4 = 8192-CB ceiling; highest qid 3071 (CBs near top) clean & exact |
| Latency (steady) | QP-only ~66-490 µs; 64-path ~965 µs (~12 µs/path). First-dump-after-reload = 65 ms cold outlier — ignore |
| Heartbeat soak | 12,712 64-path dumps/60 s + traffic → 0 err, no watchdog/reset |
| Churn/race | 267,784 dumps/10 min concurrent w/ QP create+destroy → 0 err, 0 fault, no leak, heartbeat held |
| Back-compat | `echo "<qp> 4096"` → QP-only, no header |
| Buffer cap | `echo "<qp> 5000"` → num_paths capped (41), no overflow |
| Invalid qpid | clean EINVAL (out-of-table); torn-down qid → stale-but-safe data (CB not zeroed); GSI/non-MP qid → num_paths=0 |
| Datapath | write_bw 382.66 Gb/s @ 64 paths + dump storm == 382.95 @ 8 paths idle → ~0 impact |

**Multi-NIC is NOT useful coverage:** each NIC runs an independent nicmgr instance with no
shared state, so 1 NIC fully exercises the handler. The meaningful stress axis is
intra-instance (payload size, table fill, dump rate, QP churn) — all covered above.

### Reproduce on HW
1. Patch driver in place: edit `ionic_hw_stats.c` in repo → `scp` to
   smc2 `/usr/src/ionic-26.06.9.001/rdma/drv/ionic/`, `dkms remove/build/install ionic/26.06.9.001 -k $(uname -r)`.
2. **In-place reload BOTH modules** (ionic_if.h change alters CRC, can't reload rdma alone):
   `killall ib_write_bw; rmmod ionic_rdma; rmmod ionic; modprobe ionic; modprobe ionic_rdma`.
   Then bringup `/mnt/clusterfs/bringup/vulcano_hydra_rccl_bringup.sh`. **No reboot** (reboot
   loads stale modules — this bit us repeatedly).
3. Node: `/sys/kernel/debug/ionic/<bdf>/lif0/rdma/qp_path_stats`. Path count:
   `nicctl update pipeline rdma path -p 0 --count <N>` (must recreate QPs after).
4. Find live qids: `rdma res show qp link roce_benic1p1`.

---

## What's pending (resume here after Nikhil)

1. **Driver-team question (the blocker):** the standard `rdma statistic`/netlink surface has a
   ~4 KB `res_get_common_dumpit` buffer limit (AI-1057) → can't render all 64 path blocks, and
   can hang. Asked Nikhil for the rendering approach (HDRS template #32 + AI-1057 fix is a
   driver-team item). Per-path on the *standard* surface is the actual Meta ask; the FW side
   is ready and waiting on the driver consumer.
2. **De-WIP `52b1bf7`** — real commit message / squash before raising a PR.
3. **FW-adjacent, not yet coded:** `poller.c` VALS-length validation (#31), HDRS per-path
   counter template (#32).
4. **Driver ABI commit** — `eth/ionic/ionic_if.h` in the linux-ionic repo (Nikhil's side).
5. **Platform parity** — only Vulcano/hydra proven on HW; Pulsar/Salina untested.
6. Branch is on the **fork only** — not origin, not merged, no PR.

## Gotchas learned (don't repeat)
- Don't reboot to pick up driver changes — in-place rmmod/modprobe of BOTH modules.
- Don't hack `firmware_config_default.dtb` from sim into the HW build dir — a contaminated
  clean→sim-gtest→ainic-fw sequence skips HW config-gen and produces a malformed image
  (~9.88 MB vs valid 10.62 MB) that **bricks cards**. Do a clean build with no intervening
  sim build; gate on image size == official before flashing.
- Card recovery from brick = SuC `boot_ctrl altfw` + cold reboot (boots good alt partition).
