---
name: f02 Helios-P access and operations
description: SSH access, BMC, reboot/power-cycle procedure for ctheliosp-1b114-f02-1/f02-2 Helios-P mini-rack
type: reference
originSessionId: 9524d18f-c1f7-4f0e-8e40-e678a4935707
---
## f02 Helios-P Mini-Rack

**Nodes:** `ctheliosp-1b114-f02-1.mnb.dcgpu` / `ctheliosp-1b114-f02-2.mnb.dcgpu`
- Old `.amd.com` names → NXDOMAIN from dev workstation
- **IPs shift on reboot** — last known (2026-08-07): f02-1=`10.5.229.87`, f02-2=`10.5.229.114`
- Re-resolve each session: ping `.mnb.dcgpu` from a host that can, or ask Vikram

## SSH Access

```bash
ssh prthangar@<ip>   # Conductor key + active reservation required
# Connect by IP (names don't resolve from dev workstation)
ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no prthangar@<ip>
# Strip SUT banner (prints on every login):
ssh -tt prthangar@<ip> "<cmd>" </dev/null 2>&1 | tr -d '\r' | sed 's/\x1b\[[0-9;]*m//g'
```
- `sudo` is passwordless
- `mpirun must run as root` (root has cross-node SSH keys)
- If `Permission denied (publickey)` → no active reservation, or key not registered at conductor.amd.com/user/dashboard/key-management

## BMC Access

| Node | BMC hostname | BMC IP | Creds |
|------|-------------|--------|-------|
| f02-1 | bmc-ctheliosp-1b114-f02-1.amd.com | 10.5.236.53 | root / 0penBmc |
| f02-2 | bmc-ctheliosp-1b114-f02-2.amd.com | 10.5.236.75 | root / 0penBmc |

**CRITICAL: BMC is only reachable cross-node** (f02-1's BMC from f02-2, vice versa).
**NEVER AC-cycle both nodes at once** — you lose the only jump path and need a lab ticket.

## Reboot / Power Cycle (from the PEER node)

```bash
# AC cycle (from peer node that can reach target BMC):
ssh root@bmc-ctheliosp-1b114-f02-X.amd.com "mfg-tool power-control -p 0 -a cycle -s standby"
# DC cycle:
ssh root@bmc-ctheliosp-1b114-f02-X.amd.com "mfg-tool power-control -p 0 -a cycle"

# Wait ~90s, poll i2c until 0x30 shows 09:
sshpass -p 0penBmc ssh root@bmc-ctheliosp-1b114-f02-X.amd.com 'i2cdump -y -f 6 0x20' | grep ^30:
# Then power on:
sshpass -p 0penBmc ssh root@bmc-ctheliosp-1b114-f02-X.amd.com "mfg-tool power-control -p 0 -a on"
# Host boots in ~3-4 min
```

**WARNING: `nicctl reset card` HANGS the host on this build** — use BMC AC cycle only.

## Bringup (after any reboot)

```bash
sudo bash /apps/shared/ib_tests/bringup/bringup_crossnode_f02-1.sh   # on f02-1
sudo bash /apps/shared/ib_tests/bringup/bringup_crossnode_f02-2.sh   # on f02-2
```
- Calls `set_ip_f02-{1,2}.sh` (sets IPv6 rules + demotes local table to pref 200)
- Expect: all NIC ports PORT_ACTIVE, cross-node pings PASS, "4 GPUs visible"
- bringup does NOT modprobe — assumes amdgpu already loaded
- After bringup: verify path count = 8 on all NICs: `sudo nicctl show pipeline rdma path -p 0 -b <bdf>`

## Ref doc on the nodes
`/apps/shared/f02-power-bringup-rccl.md`

## Handoff docs in dev-notes
- `f02-rccl-runbook-2026-06-10.md` — original runbook (jump host / older creds)
- `HANDOFF_helios_f02_rccl_ipv6_status_2026-07-28.md` — IPv6 RCCL status, routing config detail
- `HANDOFF_helios_f02_AI-7503_pathcount_2026-08-09.md` — AI-7503 root cause, current access, GDR sweep plan
