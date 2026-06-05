---
name: kenya-perf-3/4 sweep handoff (2026-06-05)
description: Self-contained handoff for resuming kenya-perf-3/4 QP sweep work in a new Claude session — testbed state, what was run today, all commands/files/skills used, follow-ups
type: project
---

# Handoff — kenya-perf-3/4 QP Scaling Work (session 2026-06-05)

> **Purpose:** A new Claude session should be able to pick up exactly where this session left off using only this doc + the referenced files. No prior session context required.

---

## 0. TL;DR for new session

1. Read this doc and `project_kenya_perf_baseline.md` (same dir).
2. Cards are on FW **1.130.0-a-8**, **default profile** (1×800 G), **RCN enabled**.
3. Latest sweep results are at `kenya-perf-{3,4}:/tmp/*` and `/tmp/qp_sweep_results.csv` / `/tmp/kenya_qp_sweep_report.md` on the build host.
4. **Open follow-ups** at bottom (Section 8) — pick from there if continuing perf work.
5. **Key caveat:** path-count was reduced (8 → 4 → 2) for the 2048/4092-QP tiers. If you re-run lower-QP tests first, restore paths:
   `nicctl update pipeline rdma path --profile-id 0 --count 8` on both hosts.

---

## 1. Hardware / Topology

| | **kenya-perf-3** (server) | **kenya-perf-4** (client) |
|---|---|---|
| Testbed YAML | `~/dev-notes/pensando-sw/hardware/vulcano/data/kenya-1354.yml` | `~/dev-notes/pensando-sw/hardware/vulcano/data/kenya-3190.yml` |
| Alias in YAML | perf-3 | perf-4 |
| Mgmt IP | **10.30.52.66** | **10.30.52.75** |
| BMC IP | 10.30.52.61 | 10.30.52.74 ⚠ (was not pinging from build host as of 2026-06-05 14:30 — see §7) |
| SSH creds | `root` / `docker` | `root` / `docker` |
| Hostname | `kenya-perf3` | `kenya-perf4` |
| Rack | SW N2 RU 9-10 | SW N2 RU 15-16 |
| NIC | Vulcano `VULCANO-1O800` (1p 800 G OSFP224), BDF `0000:c1:00.0` | same |
| Serial | FPF26040014 | FPF26040001 |
| Card UUID | `42424650-4632-3630-3430-303134000000` | `42424650-4632-3630-3430-303031000000` |
| MAC | `04:90:81:a7:71:20` | `04:90:81:a7:6f:58` |
| **Cable** | Back-to-back **OSFP-800G-CR8 copper** (RS-FEC required) | same |
| **RDMA device** (after default profile) | `rocep195s0f3` | `rocep195s0f3` |
| **Linux iface** (after default profile) | `enp195s0f3` | `enp195s0f3` |
| **RDMA IP** | **10.1.1.1/24**, MTU 9000 | **10.1.1.2/24**, MTU 9000 |
| Hugepages (after this session) | 65536 × 2 MB = **128 GB** | 193345 × 2 MB = **377 GB** |

> **NOTE:** Stored baseline file (`project_kenya_perf_baseline.md`) lists the device as `enp195s0f2`/`rocep195s0f2`. That was for an earlier driver/FW version. **Current correct device name is `enp195s0f3`/`rocep195s0f3`** in the default profile on 1.130.0-a-8. Use f3 going forward.

---

## 2. Current NIC State (as of session end, 2026-06-05 ~15:58 local)

| Field | Both nodes |
|---|---|
| FW (SOC-OS) | **1.130.0-a-8** on partition A |
| Profile | **default** (`device_config/1.0.0`) — *not* breakout |
| Port count | 1 |
| Port speed | **800 G**, RS-FEC, MTU 9216, Copper |
| Port admin/oper | UP / UP |
| IB state | Active, LinkUp |
| RDMA paths | **kenya-perf-3: 2**, **kenya-perf-4: 2** (last left at 2 after 4092-QP test) |
| RCN | **enabled** |
| RDMA IP | configured (10.1.1.1/2) and pingable (~0.05–0.1 ms RTT) |

Verify with:
```bash
sshpass -p docker ssh root@10.30.52.66 'sudo nicctl show card profile | head -5; \
  sudo nicctl show version firmware | grep SOC-OS; \
  sudo nicctl show port | grep -E "speed|Operational status" | head -4; \
  ibstat rocep195s0f3 | head -10; \
  ip -o addr show enp195s0f3 | head -3'
```

---

## 3. What was done this session (chronological)

1. **Health check** of both setups
   - perf-3 was up; perf-4 host AND BMC were unreachable.
   - User rebooted perf-4 via BMC (out-of-band). Host came back ~5 min later. BMC still unresponsive (out of scope — flagged in §7).

2. **Image / profile switch** — `1.130.0-a-8` `breakout (8×100 G)` → `default (1×800 G)`
   - SCP bundle from `/vol/builds/hourly/1.130.0-a-8/rudra-bundle/release-artifacts/hydra/vulcano/ainic_bundle_1.130.0-a-8.tar.gz` to `/tmp/` on both hosts (build server has `/vol/builds` mounted; target hosts don't).
   - Extract on each host.
   - `cd /tmp/ainic_bundle_1.130.0-a-8/firmware && sudo nicctl update card profile -p default -i ainic_fw_vulcano.tar` (took ~6:33 each, run in parallel).
   - `sudo nicctl reset card --all` (52 s each).

3. **RDMA bring-up**
   - `ip addr add 10.1.1.{1,2}/24 dev enp195s0f3 && ip link set enp195s0f3 mtu 9000 up`
   - `sudo nicctl update pipeline rdma path --profile-id 0 --count 8`
   - `sudo nicctl update pipeline rdma congestion-control profile --profile-id 0 --rcn enable`
   - Hugepages: perf-4 was 0, set to 75 % of MemTotal (193345 pages). perf-3 was already 65536.

4. **Basic IB test (8 QP bidir, 64 K)** → 1516.30 Gbps. Health confirmed.

5. **Scaled IB test (4092 QP bidir, 64 K)** → 1516.83 Gbps. Confirmed no PPS cliff.

6. **Full QP sweep** at 8 / 64 / 512 / 2048 / 4092 QPs, `-a` (all sizes 2 B → 8 M), bidir, iters=1024 — see §5 for results.

---

## 4. Key CLI quirks discovered (different from stored baseline / skill)

| Stored note | Actual CLI on 1.130.0-a-8 |
|---|---|
| `nicctl update pipeline rdma path -p 0 --path-count 8` | `--profile-id 0 --count 8` (`-p` is global ASIC arg; use `--profile-id`. `--path-count` doesn't exist; use `--count`.) |
| `nicctl update pipeline rdma congestion-control profile -p 0 --rcn enabled` | `--profile-id 0 --rcn enable` (value is `enable`/`disable`, not `enabled`/`disabled`) |
| Device `enp195s0f2`/`rocep195s0f2` | Device is **`enp195s0f3`/`rocep195s0f3`** in default profile on this FW |
| ibstat shows "Rate: 400" | Reports 400 Gbps line-protocol rate while port speed is 800 G — verbs-layer reporting only; actual BW is 800 G as expected. Ignore. |
| `nicctl show port -p 0 ...` | `-p` is interpreted as PCIe BDF/UUID arg → "Invalid UUID 0" error. Just use `nicctl show port` without `-p`. |
| `nicctl show version firmware` | Only shows partition B / partition A details (depending on active). No clean `--detail` partition list; use full output. |

---

## 5. Sweep Results (definitive for handoff)

**Config:** `ib_write_bw -a -b -n 1024` (bidir, all sizes, 1024 iters/size), FW 1.130.0-a-8, RCN-on, default profile.

### Per-tier parameters used (from `~/.claude/skills/run-ib` rules)

| QPs | TX | RX | `--noPeak` | paths | port |
|---:|---:|---:|:---:|---:|---:|
|    8 | 128 | 512 | no  | 8 | 18540 |
|   64 | 128 | 512 | no  | 8 | 18541 |
|  512 |  64 |  64 | yes | 8 | 18542 |
| 2048 |   8 |   7 | yes | **4** | 18543 |
| 4092 |   8 |   7 | yes | **2** | 18544 |

Path-count reduction is required by FW: `qp × paths ≤ 8192` (2048×4=8192, 4092×2=8184).

### Bandwidth (Gbps avg, bidir)

| Size | 8 QP | 64 QP | 512 QP | 2048 QP | 4092 QP |
|---:|---:|---:|---:|---:|---:|
| 2B | 0.08 | 0.11 | 0.12 | 0.12 | 0.13 |
| 64B | 2.71 | 4.05 | 4.07 | 4.03 | 4.33 |
| 256B | 14.79 | 17.83 | 17.96 | 17.51 | 19.17 |
| 1K | 60.33 | 71.52 | 71.97 | 70.53 | 76.73 |
| 4K | 278.13 | 284.51 | 285.53 | 279.21 | 301.96 |
| 16K | 1088.04 | 1114.80 | 1105.02 | 1037.90 | 1091.37 |
| 32K | 1492.48 | 1516.67 | 1519.52 | 1446.29 | 1405.29 |
| 64K | 1508.13 | 1519.16 | 1518.57 | 1468.78 | 1423.35 |
| 128K | 1521.97 | 1517.37 | 1519.17 | 1481.64 | 1432.52 |
| 1M | 1533.23 | 1520.35 | 1520.76 | 1453.69 | 1433.89 |
| **8M (peak)** | **1535.75** | 1521.14 | 1520.75 | 1492.97 | 1433.98 |
| **Δ vs 8-QP peak** | — | -0.95 % | -0.91 % | **-2.79 %** | **-6.62 %** |

Full table (all 23 sizes) and per-size msg-rate: `/tmp/kenya_qp_sweep_report.md` on the build host.

### Key observations

1. Line-rate ~1.52 Tbps bidir sustained 8 → 512 QPs (within 1 %).
2. **2048 QP dips ~3 %, 4092 QP dips ~6.6 %** at large sizes. Two mixed causes:
   - HW resource pressure at high QP×size (historical hcache pattern from `MEMORY.md` index entry "4K QP Perf Dip Analysis").
   - Path-count step-down (8 → 4 → 2) — fewer paths means less load-spreading.
3. **RCN-on no longer regresses bidir** at large sizes — vs the stored 2026-05-09 RCN-on baseline (~1.34 Tbps on 1.125.0-a-228), the 1.130.0-a-8 result is ~13 % better. RCN behavior has been improved between those two builds.
4. Knee at 32 K is uniform across all QP tiers.
5. Msg-rate peak ~9.4 Mpps at 256 B–2 K on 4092 QP.
6. All 115 (5×23) data points clean — no hangs, no RTR failures.

---

## 6. Reproducing the sweep (commands)

All artifacts live on the **build host** (the host where Claude runs SSH from):

| File on build host | Purpose |
|---|---|
| `/tmp/kenya_full_sweep.sh` | Driver script — full -a sweep, all tiers |
| `/tmp/kenya_qp_sweep.sh` | Earlier 64K-only sweep driver |
| `/tmp/kenya_qp_rerun.sh` | 2048/4092 single-size rerun script |
| `/tmp/build_report.py` | Pivots CSV → markdown tables |
| `/tmp/qp_sweep_results.csv` | Last sweep raw data (115 rows) |
| `/tmp/kenya_qp_sweep_report.md` | Final markdown report |
| `/tmp/kenya_full_sweep.out` | Stdout of the sweep run |

Per-host logs (preserved on targets):

| Host | Path | Contents |
|---|---|---|
| perf-3 | `/tmp/ib_srv_q{QPS}_sweep.log` | Server-side perftest log for tier `QPS` |
| perf-4 | `/tmp/ib_cli_q{QPS}_sweep.log` | Client-side perftest log for tier `QPS` |
| both | `/tmp/profile_switch.log`, `/tmp/card_reset.log` | Image-load logs from this session |
| both | `/tmp/ainic_bundle_1.130.0-a-8/` | Extracted bundle (use for future profile re-switch) |

### Quick re-run of one tier (template)

```bash
QPS=512; TX=64; RX=64; ITERS=1024; PORT=18550; PATHS=8
NOPEAK="--noPeak"   # set "" for QPS ≤ 256

for H in 10.30.52.66 10.30.52.75; do
  sshpass -p docker ssh root@$H \
    "sudo nicctl update pipeline rdma path --profile-id 0 --count $PATHS; \
     killall -9 ib_write_bw 2>/dev/null"
done
sleep 3

CMD="numactl --cpunodebind=netdev:enp195s0f3 ib_write_bw -d rocep195s0f3 \
     --use_hugepages -i 1 --report_gbits -p $PORT -F -q $QPS -t $TX -r $RX \
     -n $ITERS -a -b $NOPEAK"

# Server (perf-3)
sshpass -p docker ssh root@10.30.52.66 \
  "nohup bash -c '$CMD > /tmp/ib_srv_q${QPS}_x.log 2>&1' >/dev/null 2>&1 &"
sleep 8
# Client (perf-4)
sshpass -p docker ssh root@10.30.52.75 \
  "timeout 1800 $CMD 10.1.1.1 > /tmp/ib_cli_q${QPS}_x.log 2>&1"

# Inspect
sshpass -p docker ssh root@10.30.52.75 \
  "grep -E '^ *[0-9]+ +[0-9]+ +[0-9.]+' /tmp/ib_cli_q${QPS}_x.log"
```

### TX/RX/--noPeak/path-count rules (canonical, from `~/.claude/skills/run-ib/SKILL.md`)

```
abs_qps tier            → TX  RX   extra
2     ≤ abs ≤ 127       → 128 512  -
128   ≤ abs ≤ 511       → 128 383  -
512   ≤ abs ≤ 784       → 64  64   --noPeak (CQ borderline)
abs ≥ 785               → 8   7    --noPeak

CQ cap if (TX+RX)×QPs > 65,435: RX = min(RX, floor(65435/qps) - TX)
≥512 QPs: iters MUST be power-of-2 (1000 → 1024, 5000 → 8192)
qp × path_count ≤ 8192  (FW QP-table limit)
```

### Restore default state (8 paths) when done with high-QP work

```bash
for H in 10.30.52.66 10.30.52.75; do
  sshpass -p docker ssh root@$H \
    "sudo nicctl update pipeline rdma path --profile-id 0 --count 8"
done
```

---

## 7. Known issues / quirks

1. **perf-4 BMC (10.30.52.74) was unreachable from build host** throughout this session, including before *and* after the in-band reboot. The reboot itself was triggered by the user out-of-band (presumably from a network path that *can* reach the BMC). Out-of-scope flag — needs lab follow-up if BMC access is needed for power-cycle.
2. **Stored baseline RDMA device name (`enp195s0f2`/`rocep195s0f2`) is stale** — current is `f3`. The baseline file should be updated; not done this session at user discretion.
3. **Stored baseline RCN-on regression (~-12 % bidir on 1.125.0-a-228) is no longer reproducible on 1.130.0-a-8.** Either the CC fix shipped between builds or short-runtime measurements don't engage the same RCN oscillation. Not investigated.
4. **High-QP BW dip (-3 % @ 2048, -6.6 % @ 4092)** is real but path-count-reduced (8 → 4 → 2 to satisfy FW limit), so it conflates two effects (hcache pressure + path-spreading loss). To separate, would need `-D 60` runs with `nicctl show pipeline rdma stats` snapshots — see follow-up #2.
5. **perftest reports `BW peak = 0.00` at ≥512 QPs** when `--noPeak` is on. Not a failure — use BW avg column. Skill rule says always set `--noPeak` at high QPs to avoid deadlock.
6. **`/vol/builds` is NOT mounted on perf-3/perf-4** — must SCP bundle from build host.

---

## 8. Open follow-ups (pick from here to continue)

| # | Task | Why | Effort |
|---|---|---|---|
| 1 | Restore `paths=8` globally before any further low-QP work | Cards left at paths=2 from the 4092-QP test | 30 s |
| 2 | `-D 60` re-run of 2048 + 4092 QP + `nicctl show pipeline rdma stats` snapshots before/after | Disambiguate hcache vs path-count contribution to the high-QP dip | ~30 min |
| 3 | Uni-directional pass (`-q N` without `-b`) at same QP tiers | Stored baseline shows the historical RCN-on uni regression — recheck on 1.130.0-a-8 | ~20 min |
| 4 | Investigate why ibstat reports Rate 400 while port is 800 G | Cosmetic / understanding only | 15 min |
| 5 | Update `project_kenya_perf_baseline.md` with corrected device name (`f3`) and 1.130.0-a-8 RCN-on numbers | Stored numbers are now stale | 10 min |
| 6 | perf-4 BMC unreachability triage | Need for future out-of-band recoveries | lab access required |
| 7 | Other verbs (read_bw, send_bw, write_with_imm) sweep | Skill note KI-009 says write_with_imm fails at 4092 QPs on default profile — verify | ~30 min |
| 8 | `--use_rocm` (GDR) test path — but no GPU on kenya-perf nodes that I'm aware of | Out of scope unless lab confirms GPU present | N/A |

---

## 9. Skills / references used (in priority order)

| Path | Used for |
|---|---|
| `~/.claude/skills/run-ib/SKILL.md` | TX/RX rules, --noPeak rules, path-count limits, pow2 iters rule, parsing format |
| `~/.claude/skills/load-image-ainic/SKILL.md` | Profile switch procedure (`nicctl update card profile -p default -i ...`), card reset, verify |
| `~/.claude/skills/health-check/SKILL.md` | Host + NIC health checks (SSH + console) |
| `~/dev-notes/pensando-sw/claude-memory/project_kenya_perf_baseline.md` | Historical baseline, original RDMA bring-up commands (now partially stale — see §4) |
| `~/dev-notes/pensando-sw/hardware/vulcano/data/kenya-1354.yml` | perf-3 IPs / creds / console info |
| `~/dev-notes/pensando-sw/hardware/vulcano/data/kenya-3190.yml` | perf-4 IPs / creds / console info |
| `/vol/builds/hourly/1.130.0-a-8/rudra-bundle/release-artifacts/hydra/vulcano/ainic_bundle_1.130.0-a-8.tar.gz` | FW bundle for the profile switch |

---

## 10. How to bootstrap a new session quickly

In the new session, run this one block to dump current state:

```bash
for H in 10.30.52.66 10.30.52.75; do
  echo "===== $H ====="
  sshpass -p docker ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@$H \
    'hostname; uptime;
     echo "--- FW ---"; sudo nicctl show version firmware 2>&1 | grep -E "SOC-OS|Device-Config" | head -4;
     echo "--- profile ---"; sudo nicctl show card profile 2>&1 | grep "Profile name";
     echo "--- port ---"; sudo nicctl show port | grep -E "speed|Operational status" | head -4;
     echo "--- ibv ---"; ibv_devices | grep roce;
     echo "--- ip ---"; ip -o addr show enp195s0f3 2>/dev/null | head -2;
     echo "--- rdma path ---"; sudo nicctl show pipeline rdma path --profile-id 0 2>&1 | grep -iE "count|rcn" | head -5;
     echo "--- hugepages ---"; awk "/HugePages_Total/{print \$2}" /proc/meminfo'
done
```

Expected (after this session): FW 1.130.0-a-8, profile=default, 800 G UP, `rocep195s0f3` Active, 10.1.1.{1,2} on enp195s0f3, paths=2 (or whatever was last set), RCN enabled, hugepages 65536/193345.

If anything's wrong, see §3 for the bring-up sequence.
