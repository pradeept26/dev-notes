# SMC RCCL Handoff — 1.130.2-a-6 (2026-07-21)

**Purpose:** Self-contained record of loading the latest `1.130.2-a` build on the SMC1+SMC2
2-node Vulcano testbed and collecting RCCL numbers (all_reduce, broadcast, reduce). Written so a
fresh session can reproduce it cold.

**Maintainer:** Pradeep Thangaraju.

---

## TL;DR

- Loaded **`1.130.2-a-6`** (latest hourly, built Jul 20) + host tools on **both** SMC nodes.
- Bringup clean: 8× MI300X GPUs + 8 RoCE devices + 8 PORT_ACTIVE per node.
- RCCL 2-node × 8 GPU (16 ranks), meta-RoCE + ANP CTS-disable plugin, 1K–16G, `-n 20 -w 5`,
  3 runs each collective, averaged. Run-to-run spread <1%, zero validation errors.
- **Peak @16G (3-run avg):** all_reduce **361.9**, broadcast **353.7**, reduce **319.2** GB/s.
- **Harness whole-sweep avg:** all_reduce **141.8**, broadcast **125.2**, reduce **116.9** GB/s.
- Logs archived at `~/rccl_1.130.2-a-6_smc_20260721_035515/`.

---

## Cluster & Access

| Node | Host IP | BMC IP |
|---|---|---|
| smc1 (launcher) | `10.30.75.198` | `10.30.69.47` |
| smc2 | `10.30.75.204` | `10.30.69.49` |

- SSH: `root` / `docker`, **keyboard-interactive** auth (password auth is refused):
  ```bash
  sshpass -p docker ssh -o StrictHostKeyChecking=no \
    -o PreferredAuthentications=keyboard-interactive -o PubkeyAuthentication=no root@10.30.75.198
  ```
- `ubuntu` / `amd123` also works (keyboard-interactive). The RCCL harness is normally run as
  `ubuntu`; I ran as root and added the OMPI allow-root override (see gotchas).
- Shared NFS `/mnt/clusterfs` is visible on both nodes. `/vol/builds` is **NOT** mounted on the
  SMC nodes, but **is** mounted on my dev host — so I SCP'd the bundle straight from there (no
  srv3 / systest password needed).
- Testbed config of record: `~/systest-agentq/projects/ainic/meta-roce/testbeds/smc1-smc2.yaml`

---

## Build loading (both nodes, parallel)

Latest build under `/vol/builds/hourly/`:
`ls -d /vol/builds/hourly/1.130.2-a-* | sort -V | tail` → `1.130.2-a-6` (a-7 not present).

Bundle: `/vol/builds/hourly/1.130.2-a-6/rudra-bundle/release-artifacts/hydra/vulcano/ainic_bundle_1.130.2-a-6.tar.gz` (280 MB).

```bash
TAG=1.130.2-a-6
B=/vol/builds/hourly/$TAG/rudra-bundle/release-artifacts/hydra/vulcano/ainic_bundle_$TAG.tar.gz
SSH="sshpass -p docker ssh -o StrictHostKeyChecking=no -o PreferredAuthentications=keyboard-interactive -o PubkeyAuthentication=no"
SCP="sshpass -p docker scp -o StrictHostKeyChecking=no -o PreferredAuthentications=keyboard-interactive -o PubkeyAuthentication=no"

# 1. copy + extract (per node)
$SCP "$B" root@10.30.75.198:/tmp/
$SSH root@10.30.75.198 "cd /tmp && tar xzf ainic_bundle_$TAG.tar.gz"

# 2. flash (600s timeout; ~5 min for 8 NICs)
$SSH root@10.30.75.198 "cd /tmp/ainic_bundle_$TAG/firmware && nicctl update firmware -i ainic_fw_vulcano.tar"

# 3. reset
$SSH root@10.30.75.198 "nicctl reset card --all"

# 4. host tools
$SSH root@10.30.75.198 "modprobe -r amdgpu; cd /tmp/ainic_bundle_$TAG && tar xzf host_sw_pkg.tar.gz && cd host_sw_pkg && ./install.sh -y"

# 5. verify
$SSH root@10.30.75.198 "nicctl show card --detail | grep -i 'firmware version' | sort | uniq -c"   # 8x 1.130.2-a-6
```

Pre-upgrade versions: smc1 was `1.130.2-a-3`, smc2 was `1.130.0-a-51-dirty`. Both now `1.130.2-a-6`.

## Bringup (both nodes)

```bash
$SSH root@10.30.75.198 "/mnt/clusterfs/bringup/vulcano_hydra_rccl_bringup.sh"
```
Does: usermod video/render → disable_acs.sh → roce_device_rename.sh → qos_cfg_hydra.sh
(DSCP24 data / DSCP46 CTS) → modprobe amdgpu → 10bit_tags_hydra.py.

Post-bringup checks (per node): `lspci -d 1002: | grep -ci Processing` = 8 GPUs;
`ibv_devices | grep -c roce_` = 8; all ports `PORT_ACTIVE`.

---

## RCCL run

Harness: `/mnt/clusterfs/karthik/vulcano/hydra_rccl_scripts/` (`run-rccl.sh`, `setup_env.sh`,
`compute_nodes.txt` = both node IPs). Launcher = smc1.

`run-rccl.sh` invocation form (positional args are inherited by the sourced setup_env.sh):
```
./run-rccl.sh <collective> <start_size> <end_size> <num_iter> <num_warmup> <qps_per_channel>
```
It runs `${RCCL_TESTS}/build/<collective>_perf -b <start> -e <end> -f 2 -g 1 -n <iter> -c 1 -w <warmup>`
via mpirun over 16 ranks (8 GPU/node × 2), meta-RoCE (`RCCL_AINIC_ROCE=1`), ANP plugin
`amd-anp-cts-disable/build/librccl-anp.so`, `NCCL_IB_TC=96` (DSCP24<<2), `NCCL_IB_FIFO_TC=184`
(DSCP46<<2), OOB iface `ens51f0`.

Sweep driver used (3 runs × {all_reduce, broadcast, reduce}, 1K–16G):
```bash
D=/mnt/clusterfs/karthik/vulcano/hydra_rccl_scripts
for COLL in all_reduce broadcast reduce; do for N in 1 2 3; do
  $SSH root@10.30.75.198 "cd $D && export OMPI_ALLOW_RUN_AS_ROOT=1 OMPI_ALLOW_RUN_AS_ROOT_CONFIRM=1 && \
    ./run-rccl.sh $COLL 1K 16G 20 5 1" > /tmp/rccl_${COLL}_run${N}.log 2>&1
done; done
```
Parse out-of-place busBw (field 8 of each data row) per size, average across the 3 runs.

---

## Results — busBw (GB/s), out-of-place, 3-run average

| Msg Size | all_reduce | broadcast | reduce |
|---:|---:|---:|---:|
| 1K | 0.05 | 0.05 | 0.05 |
| 2K | 0.10 | 0.14 | 0.14 |
| 4K | 0.20 | 0.27 | 0.28 |
| 8K | 0.40 | 0.50 | 0.53 |
| 16K | 0.79 | 0.87 | 0.90 |
| 32K | 1.56 | 1.31 | 1.34 |
| 64K | 2.92 | 1.59 | 1.51 |
| 128K | 5.44 | 2.23 | 2.64 |
| 256K | 9.69 | 5.24 | 5.22 |
| 512K | 14.72 | 10.19 | 10.04 |
| 1M | 32.12 | 18.73 | 18.24 |
| 2M | 53.57 | 29.60 | 29.02 |
| 4M | 98.97 | 49.83 | 48.56 |
| 8M | 84.37 | 81.89 | 80.78 |
| 16M | 123.86 | 124.77 | 123.51 |
| 32M | 161.41 | 170.19 | 167.88 |
| 64M | 210.80 | 213.97 | 207.42 |
| 128M | 263.27 | 245.17 | 234.99 |
| 256M | 335.82 | 265.31 | 252.21 |
| 512M | 352.49 | 276.58 | 239.95 |
| 1G | 355.10 | 298.49 | 271.20 |
| 2G | 356.42 | 303.89 | 276.26 |
| 4G | 357.88 | 330.65 | 293.82 |
| 8G | 359.78 | 345.62 | 306.02 |
| 16G | 361.88 | 353.69 | 319.18 |

Per-run summary ("Avg bus bandwidth", harness whole-sweep metric):
- all_reduce: 141.76 / 141.76 / 141.75 → mean **141.76**
- broadcast:  125.24 / 125.31 / 125.14 → mean **125.23**
- reduce:     117.00 / 116.76 / 116.99 → mean **116.92**

Notes:
- Expected all_reduce dip at **8M** (98.97 → 84.37) — reproduced in all 3 runs; RCCL algo-transition
  artifact. broadcast/reduce climb smoothly through it.
- ~362 GB/s all_reduce @16G is in line with the historical SMC baseline (~140 harness-avg).

---

## Gotchas

1. **mpirun refuses root** — set `OMPI_ALLOW_RUN_AS_ROOT=1` + `OMPI_ALLOW_RUN_AS_ROOT_CONFIRM=1`
   in the launch env (or run the harness as the `ubuntu` user, which is the normal path).
2. **SSH auth is keyboard-interactive**, not password — `-o PreferredAuthentications=password`
   gets `Permission denied`. Use `keyboard-interactive`.
3. **Cross-node root SSH**: smc1→smc2 works (needed for mpirun launch); smc2→smc1 was not
   trusted, but that doesn't matter — only the launcher (smc1) SSHes out, and OMPI oob/back-
   connections ride `ens51f0`, not SSH.
4. `/vol/builds` is not mounted on the SMC nodes — copy the bundle from a host that has it
   (dev host / srv3) rather than expecting a local path on smc1/smc2.
5. `nicctl update firmware` uses the **`.tar`** (not `.pldmfw`). Use a 600s timeout.

---

## Artifacts

- Raw logs (9 sweeps + smoke + driver + summary): `~/rccl_1.130.2-a-6_smc_20260721_035515/`
- This handoff: `~/dev-notes/pensando-sw/smc-rccl-1.130.2-a-6-handoff-2026-07-21.md`
- Bundle still extracted in `/tmp/ainic_bundle_1.130.2-a-6/` on both nodes (280 MB; safe to rm).
