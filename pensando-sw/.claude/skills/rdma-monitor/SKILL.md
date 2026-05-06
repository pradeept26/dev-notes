---
name: rdma-monitor
description: "On-demand RDMA QP diagnostics on a remote host — LIF discovery, active QP detection, per-path RTT/DCQCN/congestion analysis, anomaly flagging. Use when user says rdma monitor, check rdma, qp status, path stats, dcqcn, congestion, rdma health, check qp, watch qp, rdma snapshot."
---

# RDMA Monitor Skill

On-demand RDMA Queue Pair diagnostics on a remote AMD Pensando NIC host.
Collects a point-in-time snapshot of active QPs, per-path statistics,
and DCQCN congestion state, then analyzes for anomalies.

For **live auto-refreshing** monitoring during long RCCL runs, use the
standalone tmux tool instead: `~/dev-notes/pensando-sw/scripts/rdma/rdma_monitor.sh`

## Input

The user's arguments are: `$ARGUMENTS`

Parse:
- **host** (required): IP address or hostname to SSH to
- **interface** (optional): network interface name to resolve LIF (e.g., `enp6s0f0np0`)
- **lif** (optional): LIF UUID directly, skips discovery
- **qp** (optional): specific QP ID to inspect (default: auto-discover active RCCL QPs)
- **scope** (optional): `quick` (default — active QPs only), `full` (all used QPs + pipeline anomalies + hw counters)

If no host specified, ask the user.

## SSH Access

Default credential chain (try in order):
1. `root` / `docker` (via sshpass if available)
2. `ubuntu` / `amd123`
3. Key-based auth (ssh-agent)

Use `-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10` on all SSH calls.

## Workflow

### Phase 1: Connect and Discover LIF

SSH to the host and resolve the LIF UUID.

```bash
# If interface was given, match it in nicctl output
sudo nicctl show lif

# If multiple LIFs, match by interface name or MAC:
cat /sys/class/net/<interface>/address
```

Pick the LIF that matches the interface. If only one LIF exists, use it.
If multiple and no interface given, list them and ask the user.

### Phase 2: Find Active QPs

```bash
# All active RCCL data QPs on this LIF
sudo nicctl show rdma queue-pair --used --rccl-data --lif <LIF> --state active
```

If `--qp` was given, use that QP directly.
If no active QPs found, report "no active RCCL QPs — no job running?" and stop.
Otherwise, pick the first active QP for detailed inspection (note total count).

### Phase 3: Collect QP Diagnostics

Run these three commands for the selected QP:

```bash
# 1. QP-level status — congestion state, active path count
sudo nicctl show rdma queue-pair \
  --queue-pair-id <QP> --lif <LIF> --status

# 2. Per-path statistics — RTT, retransmit timeouts, inactive counts, notifications
sudo nicctl show rdma queue-pair path \
  --queue-pair-id <QP> --lif <LIF> statistics

# 3. Per-path DCQCN status — congestion window per path
sudo nicctl show rdma queue-pair path \
  --queue-pair-id <QP> --lif <LIF> --status
```

### Phase 4: Full Scope (only if scope=full)

```bash
# Pipeline anomalies
sudo nicctl show pipeline internal rdma anomalies

# RDMA hardware counters (non-zero only)
sudo nicctl show rdma statistics | grep -v ': 0$'

# Port status
sudo nicctl show port

# All used QPs summary (count by state)
sudo nicctl show rdma queue-pair --used --lif <LIF> | \
  awk 'NR>1 {state[$NF]++} END {for(s in state) print s, state[s]}'
```

### Phase 5: Analyze and Report

Present a structured summary:

```
Host: <ip> | LIF: <uuid> | Active RCCL QPs: <count>
Inspected QP: <id>

QP Status
  Congestion state: <value>
  Active paths:     <count>

Per-Path Summary
┌──────────┬────────┬──────────┬──────────┬──────────────┐
│ Path ID  │ RTT    │ Inactive │ Timeouts │ DCQCN Cwnd   │
├──────────┼────────┼──────────┼──────────┼──────────────┤
│ 0        │ 1.2 us │ 0        │ 0        │ 65535        │
│ 1        │ 1.3 us │ 0        │ 0        │ 65535        │
└──────────┴────────┴──────────┴──────────┴──────────────┘

Issues: <list or "none">
```

**Flag these anomalies:**
- **High RTT**: any path with RTT significantly higher than peers (>2x median)
- **Inactive paths**: non-zero inactive count means path was marked down
- **Retransmit timeouts**: non-zero "due to timeout" = packet loss or severe congestion
- **Low DCQCN cwnd**: congestion window well below max (65535) means active back-pressure
- **Congestion state**: anything other than "normal" at QP level
- **Path imbalance**: large cwnd variance across paths = uneven load or bad link on one path
- **Pipeline anomalies** (full scope): classify per the anomaly decision tree in
  `nic/rudra/src/hydra/p4/p4plus-16/meta_roce/docs/06-debugging.md` if available

**Benign conditions to note but not alarm on:**
- Backtrack anomalies with `bt_done=1` during PFC-heavy workloads (cosmetic residuals)
- Small RTT variance across paths (<20% spread)
- cwnd at max (65535) = no congestion, healthy

## Follow-up Actions

After presenting the snapshot, offer:
- "Want me to check a different QP?" — re-run Phase 3 with new QP ID
- "Want a full scope check?" — run Phase 4 if not already done
- "Want me to check another host?" — restart from Phase 1
- "Want me to compare two hosts?" — run Phases 1-3 on both, diff the results
