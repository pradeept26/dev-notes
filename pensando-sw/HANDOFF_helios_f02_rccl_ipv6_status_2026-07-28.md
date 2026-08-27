# Handoff — Helios-P f02 RCCL / IPv6 status (verification session)

**Date:** 2026-07-28 (evening, UTC)
**Author:** Pradeep Thangaraju (prthangar) — with Claude
**Nodes:** `ctheliosp-1b114-f02-1.amd.com` / `-f02-2.amd.com` (2-node Vulcano, 4× MI300 GPU + 4× ionic RoCE NIC per node)
**Related:** Jira **AI-7298**; Slack **C0BL4RN0GFJ**; prior handoff `/home/vsampath/memories/HANDOFF_helios_f02_rccl_ipv6_2026-07-28.md`; ref doc `/apps/shared/f02-power-bringup-rccl.md`
**Companion finding (different testbed):** SMC1/SMC2 IPv6 loopback investigation — same class of bug, host-routing fix (`demote local` table). See Pradeep's memory `project_ipv6_loopback_rccl.md`.

---

## TL;DR

- **The IPv6 RCCL failure does NOT reproduce on f02 right now.** On the *current, unchanged* config, IPv6 RCCL passes reliably.
- **I changed nothing.** This entire session was read-only recon + running the stock test scripts. No `ip rule`/route edit, no `set_ip`/`bringup` re-run, no script modification (single-node isolation used a `/tmp` copy).
- **Both intra-node and inter-node IPv6 RDMA work** on the current config (see results matrix).
- **Unresolved:** *why* it failed earlier today (15:20–15:31 UTC) and passes now (≥16:12). The routing rules were already in place during the failures, so the rules alone don't explain the flip. Needs a **cold power-cycle + bringup** to prove the persisted scripts deterministically yield the passing state, plus a sync with Gunasekaran/Vijay on the exact failing state.

---

## Bottom-line status (current live config)

| Path | Test | Result |
|---|---|---|
| Inter-node + intra-node | IPv4 RCCL, 2-node × 4 GPU, 1K→16G, P2P+SHM off | ✅ PASS 24.79 GB/s |
| Inter-node + intra-node | IPv6 RCCL, 2-node × 4 GPU, 1K→16G, P2P+SHM off (×3) | ✅ PASS 24.74 / 24.78 / 24.88 GB/s, 0 wrong |
| **Intra-node only** | IPv6 RCCL, **single-node f02-1**, mpirun `-np 4` (1 GPU/rank), P2P+SHM off | ✅ PASS 25.86 GB/s, 0 wrong |
| Intra-node loopback | IPv6 `ib_write_bw` `::14→::e` (same node, over switch) | ✅ 48 GB/s |
| (quirk) | IPv6 RCCL single-node **direct `-g 4`** (1 process, 4 GPU, no mpirun) | ❌ `cu.cpp:400 'unhandled system error'` |

**Intra-node RDMA (RCCL IPv6, P2P+SHM disabled) = WORKING** — confirmed by the pure single-node mpirun run (all GPU↔GPU forced over the NIC) + the direct `ib_write_bw` loopback. The only failing mode is the script's single-process `-g 4` **direct** mode, which is a different execution model (not the RDMA path) — see "Open items".

---

## Environment / topology / access

**Hosts**

| Node | Host | Host IP | BMC | BMC IP | BMC creds |
|------|------|---------|-----|--------|-----------|
| f02-1 | ctheliosp-1b114-f02-1.amd.com | 10.5.236.107 | bmc-ctheliosp-1b114-f02-1.amd.com | 10.5.236.53 | root / 0penBmc |
| f02-2 | ctheliosp-1b114-f02-2.amd.com | 10.5.236.50 | bmc-ctheliosp-1b114-f02-2.amd.com | 10.5.236.75 | root / 0penBmc |

- **SSH:** `ssh prthangar@<node>` (Conductor key, must be registered + active reservation). Passwordless `sudo` works. Login has an ASCII banner — force a TTY (`ssh -tt`) and strip `\r`/ANSI when scripting.
- **mpirun must run as root** (root has cross-node SSH keys; user accounts do not). f02-1↔f02-2 root SSH confirmed working both directions.

**Per-domain GPU↔NIC pairing (identical both nodes)**

| Domain | RoCE dev | NIC bus | GPU |
|---|---|---|---|
| 0001 | roceP1p3s0f3 | 0001:03:00.3 | GPU0 0001:04:00.0 |
| 0002 | roceP2p3s0f3 | 0002:03:00.3 | GPU1 0002:04:00.0 |
| 0003 | roceP3p3s0f3 | 0003:03:00.3 | GPU2 0003:04:00.0 |
| 0004 | roceP4p3s0f3 | 0004:03:00.3 | GPU3 0004:04:00.0 |

**Addressing** (GID idx0 = fe80 link-local, idx1 = IPv4-mapped `::ffff:192.168.1.x`, **idx2 = global IPv6** — RCCL uses idx2). Fabric switch is the router; **router MAC `b4:db:91:9b:70:a4`**.

| NIC | f02-1 IPv6 (gw) | f02-2 IPv6 (gw) | IPv4 (f02-1 / f02-2) |
|---|---|---|---|
| P1 (enP1p3s0f3) | ::6 (gw ::7) | ::e (gw ::f) | 192.168.1.6 / .14 |
| P2 (enP2p3s0f3) | ::4 (gw ::5) | ::14 (gw ::15) | 192.168.1.4 / .20 |
| P3 (enP3p3s0f3) | ::10 (gw ::11) | ::a (gw ::b) | 192.168.1.16 / .10 |
| P4 (enP4p3s0f3) | ::1a (gw ::1b) | ::8 (gw ::9) | 192.168.1.26 / .8 |

All under `2001:db8:cafe::/…` /127 links to the switch. tclass 128 (DSCP 32). Driver: ionic kernel 26.07.11.001.

---

## Current live routing config (BOTH nodes)

```
# ip -6 rule show
101: from <P1 v6> iif lo lookup intf1_table
102: from <P2 v6> iif lo lookup intf2_table
103: from <P3 v6> iif lo lookup intf3_table
104: from <P4 v6> iif lo lookup intf4_table
200: from all lookup local          # <-- local DEMOTED from pref 0
32766: from all lookup main          # main has NO default route
# each intfN_table: "default via <gw>" + the /127 connected route
```
- Link-local (`fe80::`) present on all 4 RoCE NICs (prior "Finding 1" fix is in place).
- Gateway ND resolved to switch MAC `b4:db:91:9b:70:a4` (STALE-but-valid before each passing run).
- `net.ipv6.conf.{all,default}.forwarding = 0`.

**Key config lineage (Gunasekaran, 2026-07-28, per Slack C0BL4RN0GFJ):**
- Change 1: added `iif lo` + explicit `pref 101-104` to the source rules.
- Change 2: demoted IPv6 `local` table pref 0 → 200 (this is the same essential fix validated on SMC).

**Script contradiction to be aware of:** `set_ip_f02-{1,2}.sh` *adds* the `iif lo` rules (v6 lines 35–38), but `bringup_crossnode_f02-{1,2}.sh` **Validation 7** *warns* that `iif lo` rules are "stale/leftover from loopback" and expects none for cross-node. The scripts disagree; the live state currently has `iif lo` (set_ip wins).

---

## What was done this session (all read-only + stock tests)

1. Read-only recon on both nodes: `ip -6 rule/route`, `set_ip`/`bringup` scripts, GIDs, gateway neighbors, link-local, forwarding, `nicctl show rdma` options. **No changes.**
2. Ran `/apps/karthik/run_rccl_libionic.sh` (IPv4, 2-node) → PASS.
3. Ran `/apps/karthik/run_rccl_libionic_ipv6.sh` (IPv6, 2-node) ×3 → PASS ×3.
4. Ran IPv6 intra-node `ib_write_bw` (`roceP2 ::14` → `roceP1 ::e`, same node) → 48 GB/s.
5. Ran single-node IPv6 isolation two ways: direct `-g 4` (FAIL, quirk) and mpirun `-np 4` (PASS) — via a `/tmp` copy of the script; **originals untouched.**

**No `set_ip`, no `bringup`, no `ip rule/route`, no script edit was executed.**

---

## The fail→pass timeline (ground truth from `/apps/karthik/rccl-logs/*/config.txt`)

```
15:12  bringup_crossnode_f02-1.sh  (file mtime)
15:19  set_ip_f02-1.sh            (file mtime)  -> rules had iif lo + demote-local by here
15:20  IPv6  FAIL  (ROCM-IB)  cqe error 11
15:26  IPv6  FAIL  (ROCM-IB)
15:31  IPv6  FAIL  (ROCM-IB)
  ... gap (no runs logged) ...
16:09  IPv4  PASS  (mine)
16:12  IPv6  PASS  (mine)  24.74 GB/s
16:xx  IPv6  PASS  x2 more  24.78 / 24.88 GB/s
```
- **Same script, same `NCCL_NET=ROCM-IB` plugin** for both the failures and the passes (verified in each run's `config.txt`). Not a plugin confound.
- The `iif lo` + demote-local rules were already applied (15:19) **before** the 15:20–15:31 failures — so the rules alone did not flip it.
- The only recorded event between the last fail (15:31) and the first pass (16:12) is the IPv4 run at 16:09.

**Interpretation (unconfirmed):** most likely an incomplete/transient state at 15:20–15:31 (e.g., gateway IPv6 ND `FAILED`, or a mid-iteration rule state), cleared by ~16:00. Gateway ND was `STALE`-but-valid before each passing run. No deliberate action made it pass.

---

## Analysis vs the original hypothesis (correction)

- Earlier in the session I hypothesized the `iif lo` on the source rules breaks the RDMA path (the RDMA FIB lookup `ipv6_dst_lookup_flow` not setting `flowi6_iif=LOOPBACK`, so rules 101–104 miss → fall to `local` → own-MAC → cqe error 11). This matches Gunasekaran's root-cause note.
- **The live repro contradicts that:** `iif lo` **is** present and IPv6 RCCL passes (intra- and inter-node). So either (a) the RDMA lookup *does* honor `iif lo`, or (b) the **local-table demotion alone** is the load-bearing fix and `iif lo` is harmless here.
- Consequence: **the "remove `iif lo`" change I earlier proposed is NOT warranted** — nothing is failing on the current config. (On the SMC testbed the working rules had **no** `iif lo` + demote-local; here `iif lo` + demote-local also works. In both, **demote-local is the common essential piece.**)
- `ip -6 route get <dst> from <src>` is a **misleading** check here: `route get` performs an output lookup tagged `iif=loopback`, so it matches the `iif lo` rule and shows "via gateway" regardless. Trust QP state (`num_invalid_paths`/`key_va_err`) and actual RCCL/ib_write_bw results, not `route get`.

---

## Open items / next steps

1. **Cold power-cycle + bringup validation (highest value).** BMC AC+DC cycle both nodes, run `bringup_crossnode_f02-{1,2}.sh`, then IPv4 + IPv6 RCCL from scratch. This proves the *persisted scripts* (which still add `iif lo` + demote-local) deterministically reproduce the passing state — vs depending on hand-tweaks left in the current session.
2. **Sync with Gunasekaran/Vijay** on the exact config/ND state that produced the 15:20–15:31 failures, so we're certain this isn't an intermittent bug we happened to miss.
3. **`iif lo` decision (only after #1/#2).** If cold bringup passes with `iif lo` present, leave it (don't churn). If any residual failure traces to `iif lo`, remove it from `set_ip_f02-{1,2}.sh` v6 lines 35–38 (matches SMC + resolves the Validation-7 contradiction). IPv4 rules (lines 20–23) work today — leave them.
4. **`-g 4` single-process direct-mode failure** (`cu.cpp:400 'unhandled system error'`) — separate, low priority; not the RDMA path. Only matters if anyone relies on single-process multi-GPU direct mode. Re-run with `NCCL_DEBUG=INFO` to root-cause if needed.
5. **XGMI hang (P2P enabled)** — separate GPU/XGMI/platform issue from the prior handoff; NOT addressed here and NOT related to IPv6/NIC.

---

## Reproduction / commands

Access + scraping the banner:
```bash
ssh -tt -o StrictHostKeyChecking=no prthangar@ctheliosp-1b114-f02-1.amd.com \
  "<cmd>" </dev/null 2>&1 | tr -d '\r' | sed 's/\x1b\[[0-9;]*m//g'
```

RCCL (run as root; runner auto-detects 1 vs 2 node from its `HOSTNAMES` array):
```bash
sudo bash /apps/karthik/run_rccl_libionic.sh        # IPv4 (GID idx1)
sudo bash /apps/karthik/run_rccl_libionic_ipv6.sh   # IPv6 (GID idx2, AF IPv6)
# logs: /apps/karthik/rccl-logs/RUN_<ts>/{config.txt,hostfile,*.log,summary.txt}
```

Single-node intra-node isolation (mpirun model — the correct one):
```bash
# copy script, keep only f02-1 in HOSTNAMES OR reuse a captured mpirun line with:
#   --hostfile <f02-1 slots=4>  -np 4  ... -g 1   (P2P_DISABLE=1 SHM_DISABLE=1 GID idx2)
```

Direct intra-node loopback verbs test (over the switch):
```bash
export LD_LIBRARY_PATH=/apps/shared/images/rdma-core/build/lib:$LD_LIBRARY_PATH
ib_write_bw -d roceP1p3s0f3 -x 2 -F -D 15            # server (::e)
ib_write_bw -d roceP2p3s0f3 -x 2 -F -D 15 127.0.0.1  # client (::14) -> same node
```

QP/error inspection:
```bash
sudo nicctl show rdma queue-pair --error-disabled --detail
sudo nicctl show rdma queue-pair path --src-ip <v6> --dst-ip <v6> --json
```

Power cycle (BMC):
```bash
ssh root@<bmc-host> "mfg-tool power-control -p 0 -a cycle -s standby"   # AC
ssh root@<bmc-host> "mfg-tool power-control -p 0 -a cycle"              # DC
# then on each node: bash /apps/shared/ib_tests/bringup/bringup_crossnode_f02-N.sh
```

---

## Key paths

| Item | Path |
|------|------|
| Ref doc (power/bringup/rccl) | `/apps/shared/f02-power-bringup-rccl.md` |
| Bringup | `/apps/shared/ib_tests/bringup/bringup_crossnode_f02-{1,2}.sh` (calls `set_ip_f02-{1,2}.sh`) |
| IP/rule setup | `/apps/shared/ib_tests/bringup/set_ip_f02-{1,2}.sh` (v6 rules lines 35–38; local demote) |
| RCCL IPv4 / IPv6 | `/apps/karthik/run_rccl_libionic.sh` / `run_rccl_libionic_ipv6.sh` |
| RCCL logs | `/apps/karthik/rccl-logs/RUN_<ts>/` |
| perftest (H2H) | `/usr/bin/ib_write_bw` |
| rdma-core (libionic fix) | `LD_LIBRARY_PATH=/apps/shared/images/rdma-core/build/lib` |
| Prior handoff | `/home/vsampath/memories/HANDOFF_helios_f02_rccl_ipv6_2026-07-28.md` |
