---
name: health-check
description: >
  Parallel health check across hosts (SSH) and NICs (console) for any Vulcano setup.
  Use when the user says "health check", "check setup", "cluster health",
  "check waco health", "are the NICs healthy", or wants a quick status
  of a lab setup.
triggers:
  - health check
  - check setup
  - cluster health
  - check waco health
  - setup status
  - are the nics healthy
  - check smc health
---

# Health Check Skill

Run a parallel health check across hosts (via SSH) and NICs (via console)
for any Vulcano lab setup. Reports host reachability, NIC card status,
firmware version, and link state.

## Input

The user's arguments are: `$ARGUMENTS`

Parse:
- **Setup name** (required): e.g., `smc1`, `smc2`, `waco5`
- **Scope**: `full` (default, SSH + console), `host-only`, `nic-only`

If no setup specified, ask the user.

## Prerequisites

- SSH access to setup hosts (credentials in testbed YAMLs)
- Console access for NIC-level checks (console-mgr.py)
- Testbed YAMLs in `~/dev-notes/pensando-sw/hardware/vulcano/data/`

## Workflow

### Phase 1: Load Testbed
1. Read the testbed YAML from `~/dev-notes/pensando-sw/hardware/vulcano/data/<setup>.yml`
2. Extract: host IP, SSH credentials, NIC count, console mappings

### Phase 2: Host-Level Checks (SSH)
Run these commands on the host via SSH (all in one session):

```bash
ssh <user>@<host_ip> bash -s <<'EOF'
echo "=== HOST ==="
hostname
uptime
echo "=== NICCTL CARD ==="
sudo nicctl show card 2>/dev/null || echo "nicctl not available"
echo "=== NICCTL VERSION ==="
sudo nicctl show version 2>/dev/null || echo "nicctl not available"
echo "=== NICCTL PORT ==="
sudo nicctl show port 2>/dev/null || echo "nicctl not available"
echo "=== PCIE ==="
lspci | grep -i pensando || echo "No Pensando devices"
echo "=== IB DEVICES ==="
ibstat 2>/dev/null | head -20 || echo "ibstat not available"
EOF
```

### Phase 3: NIC-Level Checks (Console)
Use console-mgr.py to check each NIC via Vulcano console:

```bash
~/dev-notes/pensando-sw/.claude/skills/scripts/console/console-mgr.py \
  --setup <SETUP> --console vulcano --all version
```

### Phase 4: Report
Present a summary table:

```
Setup: <name> | Host: <ip> | Status: <UP/DOWN>
┌──────┬──────────┬──────────────┬────────────┐
│ NIC  │ Card     │ FW Version   │ Link State │
├──────┼──────────┼──────────────┼────────────┤
│ ai0  │ UP       │ 1.125.x-...  │ UP         │
│ ai1  │ UP       │ 1.125.x-...  │ UP         │
│ ...  │          │              │            │
└──────┴──────────┴──────────────┴────────────┘
Issues: <list any problems found>
```

Flag:
- NICs in non-UP state
- Version mismatches across NICs
- Missing PCIe devices
- Link-down ports

## Available Setups

Testbed YAMLs are in `~/dev-notes/pensando-sw/hardware/vulcano/data/`:
- `smc1.yml`, `smc2.yml` — SMC systems
- `waco1.yml` through `waco8.yml` — Waco cluster
- `gt1.yml`, `gt2.yml`, `gt4.yml` — GT systems
- `kenya-*.yml` — Kenya systems
