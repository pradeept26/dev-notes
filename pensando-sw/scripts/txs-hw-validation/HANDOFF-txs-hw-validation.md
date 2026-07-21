# HANDOFF — Hydra `txs_cmd` SQ fast-disable: HW validation

**Date:** 2026-07-16 · **Driver box:** sw-dev2.pensando.io · **Testbed:** SMC1↔SMC2 (Vulcano, hydra Meta-RoCE)
**Live report:** http://sw-dev2.pensando.io:8891/ · **Data + scripts:** this dir (`data/`, `scripts/`)

---

## 0. TL;DR

The Vulcano-only `txs_cmd` feature lets the data SQ run **auto-clear OFF** (needed for fairness at
scale) *without* the **spurious end-of-SQ PHVs** that auto-clear-off otherwise generates when the SQ
drains.

**Result:** under a **draining** workload, **txs cuts the spurious end-of-SQ PHVs ~50% vs the
shipping AC-off config at QP 2–16** (tapering to ~16–27% at QP 32/64), for a tiny scheduler
stop/re-eval cost (~18:1 favorable), with **zero BW cost (~753 Gb/s), zero latency cost, and zero
packet drops**. Benefit is **drain-specific** — under backlogged throughput the SQ never empties, so
feature ≈ baseline (no benefit, no regression). Confirmed across QP 2–64 and RCN off/on.

---

## 1. The feature and the 3 configs

`txs_cmd` = a Vulcano SPR fast-path (`__mtspr(__SPRID_TXS_CMD,...)`) that turns the TX scheduler
on/off in one instruction. On SQ drain (auto-clear off) it **stops** the SQ scheduler so it stops
emitting empty "end-of-SQ" PHVs; a race-free `sched_eval` in S2 restarts it when new work arrives.

Two knobs define the 3 images (built from the same tree, only these differ):
- **`RDMA_USE_TXS_CMD`** in `nic/rudra/src/hydra/p4/p4plus-16/rdma/include/rdma.h` (1=feature on)
- **cos3 `auto_clear`** in `nic/rudra/src/conf/hydra/vulcano/device-pf2-coredev-llc.json`
  (`tx_scheduler3`, cos 3 = data SQ)

| Image | `RDMA_USE_TXS_CMD` | cos3 `auto_clear` | Meaning |
|---|---|---|---|
| **B1** (AC-on)   | 0 | `"true"`  | data SQ auto-clear ON, no txs |
| **B2** (AC-off)  | 0 | `"false"` | data SQ auto-clear OFF, no txs — **current shipping** |
| **F** (txs)      | 1 | `"false"` | data SQ auto-clear OFF **+ txs fast-stop** — the feature |

Feature code (7 files, on the working tree; version string `1.130.0-a-51-dirty`):
`rdma.h`, `meta_roce/tx/meta_roce_tx_util.h` (`_txs_cmd_doorbell`), `tx/meta_roce_tx_s0.p4`
(S0 fast-stop, `p.stopped_txs`), `tx/meta_roce_tx_s2.p4` (`_sq_txs_reeval_if_stopped` at 5 exit
sites), `tx/meta_roce_tx_phv.p4` (`stopped_txs` bit), docs 02/07. Design notes:
`../../reference/{HYDRA-TXS-DESIGN,HYDRA-AUTOCLEAR-BEHAVIOR,PULSAR-TXS-BEHAVIOR}.md`.

---

## 2. Testbed & addressing

- **SMC1** 10.30.75.198 (server), **SMC2** 10.30.75.204 (client). SSH `ubuntu/amd123`; root pw `docker`.
- 8 Vulcano NICs/host `benic1p1..benic8p1`; RDMA dev `roce_benicNp1` (after bringup rename), else `ionic_N`.
- **Data plane is IPv6** (not the 30.x IPv4): `benicNp1` on SMC1 = `2001:db8:N::1`, on SMC2 =
  `2001:db8:(8+N)::1`. **GID index 2** = the `2001:db8:` RoCEv2 GID. Client connects to the server's
  IPv6 (e.g. `2001:db8:1::1` for benic1p1). 8 paths (`nicctl ... rdma path -p 0 --count 8`, default).
- **GPUs:** 8× MI300X/host. NIC↔GPU pairing (same PCIe switch): `benicNp1` ↔ `rocm_index N-1`
  (benic1p1↔GPU0 @05:00.0, NIC @08:00.3). Verify: `rocm-smi --showbus` + `readlink /sys/class/net/benicNp1/device`.

### Per-card image assignment (this campaign) + card UUIDs

Three images loaded **on different cards of the same hosts** — no full-host reflash.

| NIC | image | SMC1 UUID (serial) | SMC2 UUID (serial) | server IPv6 |
|---|---|---|---|---|
| benic1p1 | **B1** AC-on | `42424650-5232-3534-3830-303136000000` (FPR25480016) | `42424650-5232-3534-3830-303330000000` (FPR25480030) | `2001:db8:1::1` |
| benic2p1 | **B2** AC-off | `42424650-5232-3535-3230-303944000000` (FPR2552009D) | `42424650-5232-3535-3230-304237000000` (FPR255200B7) | `2001:db8:2::1` |
| benic3p1 | **F** txs | `42424650-5232-3534-3830-303033000000` (FPR25480003) | `42424650-5232-3534-3830-303241000000` (FPR2548002A) | `2001:db8:3::1` |

---

## 3. Build & per-card load

**Clean build (dev container, 3 images):** edit the 2 knobs, wipe build dirs, rebuild:
```
docker exec <ctr> bash -c 'cd /sw && rm -rf nic/rudra/build nic/build platform/rtos-sw/external/ainic-rtos/build \
  && make clean && make -f Makefile.ainic clean \
  && make -f Makefile.build build-rudra-vulcano-hydra-ainic-fw'   # -> /sw/ainic_fw_vulcano.tar (~3.5 min)
```
F = tree as-is; B2 = set `RDMA_USE_TXS_CMD 0`; B1 = also flip cos3 `auto_clear "true"`. Save tars as
`ainic_fw_vulcano_{F,B1,B2}.tar`.

**Per-card firmware load (key optimization — others stay up):**
```
sudo nicctl update firmware -i /tmp/ainic_fw_vulcano_B1.tar -c <benic1-uuid> -r   # -r resets that card
# ...B2 -> benic2 card... leave benic3 = F
sudo bash /mnt/clusterfs/bringup/vulcano_hydra_rccl_bringup.sh                    # restores roce_ renames
```
**Image-placement self-check** (version strings are identical): run the 1-QP lat drain per card and
match the signature — B1 spurious ≈75M, B2 ≈223M, F ≈112M.

---

## 4. Methodology (IMPORTANT)

- **Primary metric = `phb_drops`** (a free-running per-op counter that equals **spurious PHVs**;
  cross-checked: `phb_drops == NPV_phv − PSP_phv`, two independent counters agree). It is **not**
  packet loss — real loss is `nicctl show card statistics packet-buffer drop` (= 0 everywhere) and
  PRD `drops=` (~0).
- **Reset method** (per run): `asicmon -r --card <uuid>` immediately before traffic → run →
  `asicmon -v --card <uuid>` after. Gives a clean per-test delta (the raw counter free-runs). Stock
  note: `--card <uuid>` scopes asicmon to one card. `phb_drops` reported = **max across PRD engines**
  (one engine reads 0 — don't grep the first match).
- **Drain vs saturated is the crux:** the benefit only appears when the SQ actually **drains**.
  `ib_write_bw -t128` keeps 128 WQEs backlogged → SQ never empties → feature dormant. To drain at
  multi-QP use **`ib_write_bw -t1`** (1 outstanding/QP → each SQ drains per completion); `ib_write_lat`
  is the 1-QP drain anchor.
- **`phb_drops` was mis-reported at first** (grepped the wrong PRD engine → read 0). Fixed by taking
  the max engine and using the reset method. The saturated `ib_write_bw -t128` matrix therefore only
  shows "no regression", not the benefit.

---

## 5. Results

### 5.1 Multi-QP DRAINING (`ib_write_bw -t1`, 512B) — spurious PHVs (phb_drops), RCN off
| QP | B1 (AC-on) | B2 (AC-off) | F (txs) | **F vs B2** |
|----|-----------|-------------|---------|-------------|
| 2  | 85M  | 285M  | 143M  | **−50%** |
| 4  | 139M | 565M  | 285M  | **−50%** |
| 8  | 280M | 1121M | 558M  | **−50%** |
| 16 | 487M | 1764M | 906M  | **−49%** |
| 32 | 724M | 2005M | 1470M | −27% |
| 64 | 833M | 1305M | 1102M | −16% |

RCN on ≈ identical (−50%..−14%). 1-QP `ib_write_lat` anchor: B2 223M → F 110M (**−51%**), RCN off/on.
Context: AC-off (B2) ~triples spurious PHVs vs AC-on (B1); txs recovers ~half.

### 5.2 Mechanism / cost (full asicmon, drain, e.g. QP8, RCN off)
| metric | B1 | B2 | F |
|---|---|---|---|
| Doorbell Sched0 (SQ wake-ups) | 376M | 62M | 93M |
| TXs0 Clear (scheduler-stop events) | 707M | 86M | 169M |
| hcache rd hit % | 99.9 | 99.8 | 99.8 |
| XOFF% / phv_drop / real drops | 0 / 0 / 0 | 0 / 0 / 0 | 0 / 0 / 0 |

F pays ~+31M Sched0 and ~+83M Clear over B2 (the txs stop+re-eval) to remove ~560M spurious PHVs
(~18:1). AC-off itself cuts SQ doorbells ~4–6× vs AC-on under drain (and ~230× under saturation).

### 5.3 Saturated controls (`ib_write_bw -t128`) — no drain, no regression
512B: F vs B2 = −2..−3% at all QP. 1M: F ≈ B2 ≈ ±0% at all QP. (SQ stays backlogged.)

### 5.4 BW size-sweep (`ib_write_bw -a -n 10000` bidir) — no regression
Peak bidir BW ~**753 Gb/s** for B1/B2/F at every QP 2/4/8/16/32/64, RCN off/on.

### 5.5 Latency size-sweep (`ib_write_lat -a`, QP1, host mem) — no regression
t_avg and p99 identical across B1/B2/F at all sizes (2B ~4.87µs, 64K ~7.0µs, 1M ~27.2µs, 8M ~178.7µs).

### 5.6 GDR / GPUDirect (`--use_rocm`, AC-on card, GPU0)
Stock `ib_write_lat` lacks `--use_rocm`; use `/mnt/clusterfs/visampath/ib_write_lat` (ROCm-enabled).
- GDR adds ~1.5–3.5µs vs host mem (2B 8.3, 64K 8.5, 1M 28.8, 8M 180.5µs; default inline).
- **Inline hurts GDR**: at 2B, `-I 0`=6.5µs < `-I 24`=7.8 < `-I 220`(default)=8.3 — inlining forces
  the CPU to read GPU memory. Use `-I 0` for GPU-memory small-message latency.
- `-H -U` per-iteration distribution (`-s2 -I0`): 96% in 6–7µs, p99 9µs, p99.9 12µs, no outliers >15µs.
  Fast (~4.5µs) samples are **sporadic, no periodicity**, but locally coupled — ~74% immediately
  follow a ~9µs slow op (slow→fast jitter compensation, both averaging the 6.5µs mode). No systematic
  scheduler artifact. (Note: the visampath binary prints the `-H -U` list twice — 2 dumps concatenated.)

### 5.7 Correctness (all runs)
`nicctl packet-buffer drop` = 0 (all cards/ports); rdma anomalies clean pre/post; phv_drop=0; XOFF=0%.

---

## 6. How to reproduce (`scripts/`)

All driver scripts SSH from sw-dev2 to SMC1 (server) + SMC2 (client). `export SSHPASS=amd123`.
- **`spur.sh`** `<label> <dev> <s1uuid> <s2uuid> <srv_ipv6> <mode bw|lat> <qp> <size> <rcn off|on> [txdepth]`
  — one reset-method run; appends a row to `/tmp/results2/spurious.csv`. `phb_test.sh` = older 2-workload variant.
- **`runA.sh`** = spurious matrix (`-t128` sat 512B+1M, QP 2–64, RCN off/on, + lat anchor).
  **`runD.sh`** = the **draining** sweep (`-t1` 512B, QP 2–64, RCN off/on) — the headline data.
- **`runB.sh`** = BW size-sweep (`-a -n 10000`, QP 2–64). **`runC.sh`** = latency sweep (`-a`, QP1).
- **`parse_asic.sh` / `parse_asicv.sh`** = re-parse saved `after.txt`. **`gen_report2.py`** = markdown
  report. **`gen_html.py`** = the HTML page (writes `/home/pradeept/txs-report/index.html`).

**GDR latency** (must run as root for GPU access):
```
BIN=/mnt/clusterfs/visampath/ib_write_lat
# server SMC1 / client SMC2 (add server IPv6 on client); GPU paired to the NIC
sudo numactl --cpunodebind=netdev:benic1p1 $BIN -d roce_benic1p1 -x 2 --use_rocm=0 -F -p 18515 -a -n 10000 --ipv6-addr [2001:db8:1::1]
# per-iteration dump for tail analysis: add  -s 2 -I 0 -H -U
```

**RCN toggle** (per card, both hosts): `sudo nicctl update pipeline rdma congestion-control profile -p 0 --rcn enable|disable -c <uuid>`

**Report server** (on sw-dev2): `cd /home/pradeept/txs-report && python3 -m http.server 8891 --bind 0.0.0.0` (not persistent — dies on reboot; make a systemd unit if needed).

---

## 7. Artifacts (`data/`)
- `spurious.csv` — 117 spurious/asicmon runs (label,mode,qp,size,rcn,phb_drops,NPV,PSP,spurious,Sched0,Clear,real_drop,metric).
- `REPORT2.md`, `report.html` — compiled reports. `gdr/*.log` — raw GDR latency logs (default / -I24 / -n10000 / -s2 -H -U).
- `results2-full.tar.gz` — everything incl. per-run `after.txt` asicmon snapshots + `bwsweep/` + `latsweep/`.
- **Note:** live data lives under `/tmp/results2` on sw-dev2 (ephemeral) — this archive is the durable copy.

---

## 8. Known issues / gaps / follow-ups
- **RCCL blocked** — `mpirun` inter-node bootstrap fails/hangs after SMC1's reboot (root override
  applied via `OMPI_ALLOW_RUN_AS_ROOT`; GPUs healthy; firewall clear; ens51f0 up; worked Jul-13
  `baseline_run.log`). Post-reboot MPI-env regression; fix OMPI oob transport, then run the collectives.
- GDR tested on **AC-on only** — 3-way GDR (AC-off/txs) not yet run (would show if txs tightens GDR tail).
- GPU index is inferred (skill table + BDF adjacency + successful run), not a rigorous PCIe-tree proof.
- Latency-sweep HTML column labeled t_avg is actually t_typical (parser offset) — conclusion unaffected.
- Report `http.server` is not reboot-persistent; SMC1 required a BMC/APC power-cycle recovery once
  (NIC FW-down + ionic crash) — see incident notes if it recurs.

---

## Phase 3 — kenya-perf-3/4 800G reproduction (2026-07-21)

Reproduced the validation at **800G** (kenya-perf-3 10.30.52.66 / perf-4 10.30.52.75, single Vulcano
each, 1×800G `default` profile). Images rebuilt off `origin/1.130.2-a` (matches kenya's FW line),
branch rebased (`d7960d67471`). Full reflash per config (single NIC → no per-card trick); switching
from the stale 4×200G breakout to 1×800G needed `nicctl update card profile --profile default --image
<tar>` + **host reboot** (card reset alone is not enough for breakout change; a same-breakout firmware
swap only needs card reset). dev `rocep195s0f3`, IPv4 19.0.0.2/.3 same /24, **GID idx 1**, 8 paths.
Same one-pass suite (A–E × RCN off/on) + completeness gate; all 3 gated PASS.

**Drain spurious PHVs (ib_write_bw -t1, 512B, RCN off) — feature reproduces at 800G:**
| QP | B1 (AC-on) | B2 (AC-off) | F (txs) | F vs B2 |
|----|-----------|-------------|---------|---------|
| 2  | 85M  | 367M  | 175M  | −52% |
| 4  | 157M | 732M  | 350M  | −52% |
| 8  | 277M | 1169M | 662M  | −43% |
| 16 | 505M | 1290M | 960M  | −26% |
| 32 | 659M | 1712M | 1303M | −24% |
| 64 | 748M | 1215M | 1093M | −10% |

Same shape as SMC 400G (≈50% cut at low QP, tapering at high QP); AC-off penalty is even larger at
800G. No regression: BW ~1517–1534 Gb/s bidir (800G line rate) across B1/B2/F all QP; latency ~4µs
identical; zero packet drops; anomalies clean. Report: http://sw-dev2.pensando.io:8891/kenya/ .
Raw archives: `results_kenya_{B1,B2,F}.tar.gz` (data/ or the report dir).

---

## Phase 4 — SMC 3-way RCCL collectives (2026-07-21)

Closed the previously-blocked RCCL gap (the post-reboot MPI bootstrap issue is resolved — official
`1.130.2-a-6` RCCL baseline collected same day). Ran a **3-way collective sweep on SMC1+SMC2, 2-node
× 8 MI300X = 16 ranks**, meta-RoCE + ANP CTS-disable plugin, harness
`/mnt/clusterfs/karthik/vulcano/hydra_rccl_scripts/run-rccl.sh <coll> 1K 16G 20 5 1`, launched from
smc1 (root, `OMPI_ALLOW_RUN_AS_ROOT{,_CONFIRM}=1`). **Full 6 collectives × 3 runs** each.

- **B2** = the currently-loaded official `1.130.2-a-6` (functionally AC-off shipping) — no reflash.
- **F** and **B1** = fw-only reflash of the 1.130.2-a rebased txs-branch tars (`d7960d67471`) on **all
  8 NICs both nodes** (`nicctl update firmware -i` + `reset card --all` + bringup; same 1×400 breakout →
  **no host reboot**). Host RCCL stack unchanged, so any busBw delta is purely firmware.

**Image identity** (all 3 share the SOC-OS build string; B1 additionally shows `-dirty` from the cos3
json edit) was proven behaviorally by the 1-QP `ib_write_lat` drain self-check on benic1p1 before each
sweep — spurious-PHV ladder **B1 ~75M < F ~113M < B2 ~223M** (matches the SMC 400G signature).

**Result — no RCCL regression (harness whole-sweep avg, GB/s, 3-run mean):**
| collective | B2 | F | B1 | F vs B2 | B1 vs B2 |
|---|---|---|---|---|---|
| all_reduce | 141.68 | 141.44 | 141.65 | −0.17% | −0.02% |
| alltoall | 43.43 | 43.38 | 43.06 | −0.13% | −0.87% |
| alltoallv | 31.79 | 31.68 | 31.58 | −0.33% | −0.67% |
| broadcast | 125.00 | 124.87 | 124.98 | −0.10% | −0.01% |
| reduce_scatter | 135.38 | 134.21 | 135.00 | −0.86% | −0.28% |
| all_gather | 137.76 | 137.63 | 137.63 | −0.10% | −0.10% |

all_reduce peak@16G 360.5/360.2/359.0 (B2/F/B1); largest peak deviation −1.5% (B1 alltoall). All within
run-to-run noise, `#wrong 0` on every size/run, anomalies clean, packet-buffer drop=0. As expected —
RCCL keeps the SQ backlogged so the txs fast-disable never fires; this is a pure **no-regression
confirmation at the real collective level**. B2 matches the 2026-07-21 official baseline (all_reduce
~141.8 avg / ~362 @16G). Report: http://sw-dev2.pensando.io:8891/smc-rccl/ . Raw archives:
`results_smc_rccl_{B2,F,B1}.tar.gz`. Testbed restored to official `1.130.2-a-6` after the runs.

### Phase 4b — A-B-C-A confound test (all_reduce + alltoall, 5 runs each)

The first sweep showed B2 nominally highest in all 6 collectives (F/B1 lower by ≤0.9%), at the edge of
run-to-run noise. To rule out a measurement-order/reflash confound, ran an **A-B-C-A** on the two
collectives of interest: `B2_a → F_b → B1_b → B2_c`, each on a fresh reflash+bringup, B2 bracketed to
detect drift. Harness-avg (GB/s):

| coll | B2_a | F_b | B1_b | B2_c | F vs B2 | B1 vs B2 | B2 drift |
|---|---|---|---|---|---|---|---|
| all_reduce | 141.735 | 141.440 | 141.582 | 141.641 | −0.17% | −0.07% | −0.07% |
| alltoall | 43.412 | 43.246 | 42.881 | 43.408 | −0.38% | −1.22% | −0.01% |

**B2 is stable across the two brackets (drift ≤0.07%), so the confound is ruled out** — the small gaps
are real, not order/warmup artifacts. On `alltoall` all three bands are cleanly separated:
**AC-off (B2) > txs (F) > AC-on (B1)**. On `all_reduce` the effect is negligible (B2 vs F barely
separated ~0.17%; B1 overlaps).

**Corrected conclusion:** it is *not* pure noise — there is a genuine, tiny throughput ordering
**AC-off ≥ txs ≥ AC-on**. AC-on (B1) is actually the *slowest* (up to ~1.2% on alltoall), consistent
with auto-clear's much higher SQ scheduler doorbell churn (~230× under saturation per the IB data);
txs (F) adds only a sliver of S2 re-eval overhead (≤0.4% under B2). Still comfortably **no regression**
for the feature (F within 0.4% of shipping B2). Data: `results_smc_rccl_aba/` + `ABA_summary.txt`.
