---
name: rdma-monitor skill plan
description: Plan to create a private /rdma-monitor skill for on-demand RDMA QP diagnostics using nicctl commands via Claude
type: project
originSessionId: 06475840-2dc3-46f5-b4bd-43a25d851d5f
---
**Plan:** Create a `/rdma-monitor` private skill (SKILL.md only, no wrapper script) that teaches Claude to do on-demand RDMA QP diagnostics.

**Why:** The existing `rdma_monitor.sh` tmux dashboard is great for live monitoring during RCCL runs, but a Claude skill enables interactive debugging — collect snapshots, analyze anomalies, flag high RTT/congestion/inactive paths, and answer follow-ups.

**Two tools, two use cases:**
- `scripts/rdma/rdma_monitor.sh` — standalone tmux dashboard for live monitoring (keep as-is)
- `/rdma-monitor` skill — Claude-driven on-demand diagnostics with analysis

**Key nicctl commands the skill should use:**
- `nicctl show lif` — LIF discovery
- `nicctl show rdma queue-pair --used --rccl-data --lif <LIF> --state active` — find active QPs
- `nicctl show rdma queue-pair --queue-pair-id <QP> --lif <LIF> --status` — QP-level congestion/paths
- `nicctl show rdma queue-pair path --queue-pair-id <QP> --lif <LIF> statistics` — per-path RTT/timeout/inactive
- `nicctl show rdma queue-pair path --queue-pair-id <QP> --lif <LIF> --status` — per-path DCQCN cwnd

**How to apply:** Model after existing repo skills from `pradeept26/hydra-meta-roce-structure` branch. Place in `~/dev-notes/pensando-sw/.claude/skills/rdma-monitor/SKILL.md`. Symlink via setup-skills.sh.
