# Handoff — Helios-P f02: AI-7503 RDMA path-count mismatch (root-caused + fixed)

**Date:** 2026-08-09 (debug session 2026-08-07)
**Author:** Pradeep Thangaraju (prthangar) — with Claude
**Nodes:** `ctheliosp-1b114-f02-1` / `-f02-2` (2-node Vulcano cross-node, 4× ionic RoCE NIC + 4× MI450 GPU per node)
**Jira:** AI-7503 (root-caused, fix verified, comment posted, safe to close)
**Related prior handoffs:** `HANDOFF_helios_f02_rccl_ipv6_status_2026-07-28.md` (had the correct debug procedure), `f02-rccl-stale-pa-debug-2026-06-08.md` (different bug — cache pollution)

---

## TL;DR

- AI-7503 reported as "[Vulcano a14] RDMA write fails with IBV_WC_REM_ACCESS_ERR — rkey validation regression." **That premise is wrong.**
- **Real root cause: RDMA multipath path-count mismatch.** f02-1 had `path count = 1` on all 4 NICs; f02-2 had `8`. **Not an a-14 firmware regression.**
- Fix: `sudo nicctl update pipeline rdma path -p 0 --count 8` on f02-1 (all NICs). Verified — exact Jira repro passes ~1078 Gb/s (CPU mem) and ~1202 Gb/s (GDR `--use_rocm=0`).
- Setup left **matched at path count 8 on both nodes**. Vikram took the setup back on 2026-08-07.
- **Pending when setup is free:** GDR BW sweep (64/512/1024/2048 QP × {64K,1M}) — full plan at the bottom.

---

## Access (IMPORTANT — changed from older handoffs)

- **Hostnames are `.mnb.dcgpu`, NOT `.amd.com`:** `ctheliosp-1b114-f02-1.mnb.dcgpu` / `-f02-2.mnb.dcgpu`.
  - The old `.amd.com` names return **NXDOMAIN** from the dev workstation, and the old `10.5.236.x` IPs are **not routable** from it.
- **IPs shift on reboot.** Last known (2026-08-07): **f02-1 = `10.5.229.87`, f02-2 = `10.5.229.114`**. Re-resolve each session (ping the `.mnb.dcgpu` name from a host that can, or ask Vikram).
- **SSH: `ssh prthangar@<ip>`** (Conductor key + **active reservation** required). Guna's login is no longer needed.
  - From the dev workstation the names don't resolve → **connect by IP**. Use `-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no`.
  - Conductor SUT banner prints on every login → filter it (`sed -n '/MARKER/,/MARKER/p'` around your command, or `tr -d '\r'`).
  - `sudo` is passwordless.
- If `Permission denied (publickey)` → no active reservation, or key not registered at conductor.amd.com/user/dashboard/key-management. (My ed25519 + rsa keys are registered.)

---

## Topology / addressing (both nodes, a-14)

- **FW:** `1.130.2-a-14` (SOC-OS) on all NICs, both nodes.
- **perftest:** `/apps/shared/perftest/ib_write_bw` — **ROCm-enabled** (supports `--use_rocm=<id>` and `--use_rocm_dmabuf`). (The `/usr/bin` one does not.)
- **NIC ↔ GPU pairing is by PCI domain** (`000X`). Each domain = one NIC+GPU pair:

| NIC (rdma dev) | NIC BDF | GPU (`--use_rocm`) | GPU BDF | IPv6 f02-1 | IPv6 f02-2 |
|---|---|---|---|---|---|
| ionic_0 | 0001:01:00.0 (bus 0001:03:00.3) | **0** | 0001:04:00.0 | ::6 | ::e |
| ionic_1 | 0002:01:00.0 | 1 | 0002:04:00.0 | ::4 | ::14 |
| ionic_2 | 0003:01:00.0 | 2 | 0003:04:00.0 | ::10 | ::a |
| ionic_3 | 0004:01:00.0 | 3 | 0004:04:00.0 | ::1a | ::8 |

- IPv6 under `2001:db8:cafe::/127` links; **GID idx2 = global IPv6** (`-x 2`). Router/switch MAC `b4:db:91:9b:70:a4` (gws ::7/::f/::11/::b … ND STALE-but-valid is normal).
- Host IPv6 routing on both nodes is the known-good config: rules 101–104 (`iif lo`), `local` demoted to pref 200. Verified correct during this session.

---

## AI-7503 root cause (path-count mismatch)

### Symptom
Single/multi-QP `ib_write_bw` (IPv6) fails on first completion: `ionic_comp_msn cqe with error 11 … syndrom 0xa`, `ccnt=0`. Post-fail anomalies: `spec_failure / rollback`, `ack_msn not advancing`, `requester RX error-disabled: 0x4`.

### The finding — it's DIRECTIONAL
| Test | Path | Result |
|---|---|---|
| A | f02-2 → **f02-1** (inter-node) | ❌ FAIL (cqe 11 / syndrom 0xa) |
| B | f02-1 → f02-2 (inter-node) | ✅ 405 Gb/s |
| Loop | f02-1 → f02-1 (`::4`→`::6`, over switch) | ✅ 397 Gb/s |

Both nodes a-14 → if it were a-14 code, reverse + loopback would also fail. They don't. Fault follows **f02-1 as the WRITE target**.

### Mechanism (the smoking gun)
```
sudo nicctl show pipeline rdma path -p 0 -b 0001:01:00.0
```
- **f02-1: Path count = 1** (all 4 NICs)
- **f02-2: Path count = 8** (all 4 NICs)

f02-2 (requester) spreads WRITEs across 8 paths (8 entropy/UDP-src); f02-1 (responder) only had 1 path provisioned → 7/8 paths never tracked/ACKed → requester `snd_una` never advances → retries exhausted → `syndrom 0xa` (RETRY_EXC). `cqe error 11 (REM_ACCESS)` is a downstream driver mapping, **not** an rkey/access reject.

Responder-side proof (`nicctl show rdma queue-pair path --src-ip <v6> --dst-ip <v6> --json`): f02-1 **received** the data (`receive_next_flow_sequence_number` advanced), sent **no NAK** (`fatal_nak_sent = PATHID_UNS`, `ack_status = 97`); f02-2 requester `send_unacknowledged_flow_sequence_number = 0`, `rtt = 0`, 1 RTO retx.

### Why f02-1 was at 1
Bringup step `nicctl update pipeline rdma path -p 0 --count 8` (in `/apps/shared/ib_tests/bringup/qos_cfg_meta_roce.sh`) was **not applied on f02-1**, leaving the default of 1.

### Fix + verification
```bash
# on f02-1, all NICs:
sudo nicctl update pipeline rdma path -p 0 --count 8   # (repeat per -b 000X:01:00.0 if needed)
```
- Exact Jira minimal repro (bidir, QP32, 8 MB, f02-2→f02-1): **1077.68 Gb/s avg, RC=0, 0 errors** (was 100% fail).
- GDR (`--use_rocm=0`, GPU0): **1202.40 Gb/s avg, RC=0**.
- Jira comment posted (root cause + isolation + fix + verify). Recommend re-scope to bringup/provisioning gap and ensure `qos_cfg_meta_roce.sh` runs on **all** nodes; flag peer path-count mismatch in setup validation.

---

## Correct debugging procedure (reusable for cqe-error-11 / directional RDMA fails on f02)

1. **Check path count both nodes:** `nicctl show pipeline rdma path -p 0 -b <bdf>` → must MATCH between peers.
2. **Directional isolation:** unidir A (client→target), unidir B (reverse), + intra-node loopback on the target (rules out card vs network).
3. **QP path state (not `route get`):** `nicctl show rdma queue-pair path --src-ip <v6> --dst-ip <v6> --json` → look at `send_unacknowledged_flow_sequence_number` (snd_una), `rtt`, `ack_status`, `fatal_nak_sent`, `receive_next_flow_sequence_number`.
4. **Anomalies:** `nicctl show pipeline internal rdma anomalies -b <bdf>` and error-disable decode via `nic/rudra/src/hydra/p4/p4plus-16/meta_roce/docs/06-debugging.md` (sqcb3/sqcb4/rqcb2 bit tables).
5. **State reset between runs:** `nicctl clear pipeline internal state -b <bdf>` (note: does NOT clear translation cache — that needs AC cycle; see stale-PA handoff).

Skill: `/debug-meta-roce`. QP CBs reset when perftest tears down, but `path --json` by src/dst IP persists the last state.

---

## PENDING — GDR BW sweep (run when setup is free)

Goal: verify BW at 64/512/1024/2048 QP with `--use_rocm`, at **64K and 1M**. Direction f02-2→f02-1, ionic_0↔GPU0, bidir, IPv6 idx2. Built per `/run-ib` skill (single NIC → abs_qps = qp).

| QPs | `-t` | `-r` | path cnt (both nodes) | `-n` @64K | `-n` @1M | `--noPeak` |
|----:|:---:|:---:|:---:|:---:|:---:|:---:|
| 64 | 128 | 512 | 8 | 5000 | 1000 | no |
| 512 | 64 | 63 | 8 | 1024 | 256 | yes |
| 1024 | 8 | 7 | 8 | 1024 | 128 | yes |
| 2048 | 8 | 7 | **4** | 512 | 64 | yes |

Rules applied:
- **TX/RX tiers:** 2–127→128/512; 128–511→128/383; 512–784→64/64; ≥785→8/7.
- **CQ cap** `RX = min(RX, floor(65435/qp) − TX)` → 512 QP gives RX=63.
- **Power-of-2 iters + `--noPeak` for qp ≥ 512** (hang avoidance).
- **Path count constraint `qp × path ≤ 8192`:** keep 8 for 64/512/1024 (1024×8=8192 = limit); **2048 needs path=4 on BOTH nodes** (2048×4=8192), then **restore 8 on both** after and verify.
- **GPU buffer `QP×size×2` (once):** @64K 8 MB→256 MB; @1M 128 MB→4 GB (2048) — fits MI450 HBM.
- FW QP limit: 2048 ≤ 4096 (build ≥181). If `Failed to modify QP N to RTR` → flag FW resource limit, SKIP.

Command per run:
```bash
ib_write_bw -d ionic_0 -x 2 -F --report_gbits --ipv6-addr -b -s <65536|1048576> \
  --use_rocm=0 -q <QP> -t <TX> -r <RX> -n <ITERS> [--noPeak] \
  --bind_source_ip <::6 server | ::e client> -p 18515 [<2001:db8:cafe::6> on client]
```
Cleanup between runs: `pkill -f ib_write_bw` + `nicctl clear pipeline internal state -b 0001:01:00.0` on both. Leave path count 8/8 at the end.

---

## Key paths / commands

| Item | Value |
|---|---|
| perftest (ROCm) | `/apps/shared/perftest/ib_write_bw` |
| bringup path-count step | `/apps/shared/ib_tests/bringup/qos_cfg_meta_roce.sh` (`--count 8`) |
| bringup (crossnode) | `/apps/shared/ib_tests/bringup/bringup_crossnode_f02-{1,2}.sh` |
| debug doc (error-disable decode) | `nic/rudra/src/hydra/p4/p4plus-16/meta_roce/docs/06-debugging.md` |
| testbed yaml | `~/systest-agentq/projects/ainic/meta-roce/testbeds/heliosp-f02.yaml` |
