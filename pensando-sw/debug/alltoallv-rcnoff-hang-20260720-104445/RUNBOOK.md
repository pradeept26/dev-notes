# Runbook: clean-state reproduction of alltoallv RCN-off hang

**DESTRUCTIVE steps below — coordinate with Guna first (it's his run).**
Nodes: GT-1 10.30.69.101, GT-4 10.30.69.98. SSH root/docker. Sequential SSH only.
Script dir on nodes: `/home/amd/vul-rccl-benchmark`.

SSH prefix:
```
SSHP="sshpass -p docker ssh -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no"
```

## 0. Snapshot already saved
Wedged-state evidence: this directory (gt4-qp23/, gt1-qp23-peer/, README.md). Safe to tear down.

## 1. Stop the current run (both nodes)
```
$SSHP root@10.30.69.101 "pkill -9 -f 'run.py|alltoallv_perf|mpirun' ; sleep 2; pgrep -af alltoallv_perf | wc -l"
$SSHP root@10.30.69.98  "pkill -9 -f 'run.py|alltoallv_perf|mpirun' ; sleep 2; pgrep -af alltoallv_perf | wc -l"
```

## 2. Clear NIC state (both nodes) + re-bringup
```
# reset cards
$SSHP root@10.30.69.101 "sudo nicctl reset card --all"; sleep 60
$SSHP root@10.30.69.98  "sudo nicctl reset card --all"; sleep 60
# verify 8 cards up each
$SSHP root@10.30.69.101 "sudo nicctl show card | grep -c 'CARD_UP'"   # expect 8
$SSHP root@10.30.69.98  "sudo nicctl show card | grep -c 'CARD_UP'"   # expect 8
# re-bringup (Guna's chained setup) on each
$SSHP root@10.30.69.101 "cd /home/amd/vul-rccl-benchmark && bash setup.sh"
$SSHP root@10.30.69.98  "cd /home/amd/vul-rccl-benchmark && bash setup.sh"
```
(If setup.sh not present, run Guna's per-node scripts: gtN_vulcano_multiplane_bringup_dynamic.sh,
gt_nodeN_rename_mp_roce.sh, gtN_vip_routes.sh, rccl_qos.sh.)

## 3. Filter setup_env.sh to alltoallv only (GT-1, the launcher)
```
$SSHP root@10.30.69.101 "cd /home/amd/vul-rccl-benchmark && for c in all_reduce alltoall broadcast reduce_scatter all_gather reduce scatter gather sendrecv; do sed -i \"s|^\([[:space:]]*\)\\\"\${c}\\\"$|\1#\\\"\${c}\\\"|\" setup_env.sh; done"
```
Restore afterwards:
```
$SSHP root@10.30.69.101 "cd /home/amd/vul-rccl-benchmark && sed -i 's|^\([[:space:]]*\)#\"\(.*\)\"|\1\"\2\"|' setup_env.sh"
```

## 4. CONTROL: RCN enabled, 1 iter (expect ~7 min, ~23 GB/s)
```
for n in 10.30.69.101 10.30.69.98; do $SSHP root@$n "for p in 0 1 2 3 4 5 6 7; do sudo nicctl update pipeline rdma congestion-control profile -p \$p --rcn enable; done"; done
$SSHP root@10.30.69.101 "cd /home/amd/vul-rccl-benchmark && python3 run.py --runs 1 --output repro_alltoallv_rcn 2>&1 | tail -40"
```

## 5. REPRO: RCN disabled, run 2-3x for consistency (expect hang)
```
for n in 10.30.69.101 10.30.69.98; do $SSHP root@$n "for p in 0 1 2 3 4 5 6 7; do sudo nicctl update pipeline rdma congestion-control profile -p \$p --rcn disable; done"; done
# verify disabled
$SSHP root@10.30.69.101 "sudo nicctl show rdma congestion-control profile -p 0 | grep -i 'Rate control'"

# START MONITORS FIRST (separate terminals, one per node):
#   ./monitor_qp_collapse.sh 10.30.69.98  0000:03:00.0 10
#   ./monitor_qp_collapse.sh 10.30.69.101 0000:03:00.0 10
# then launch the run:
$SSHP root@10.30.69.101 "cd /home/amd/vul-rccl-benchmark && timeout 1200 python3 run.py --runs 1 --output repro_alltoallv_cc_1 2>&1 | tail -40"
```
Repeat run for `_cc_2`, `_cc_3`. A hang = monitor shows QPs marching to active0>0 / cwnd0>0 / outstanding>0
and the run not completing (0-byte temp_alltoallv_iteration_1.txt after minutes).

## 6. Capture on hang (before killing)
```
# re-run the capture block from this session against a wedged QP:
#   nicctl show rdma queue-pair --error-disabled / --state error
#   find a QP with Active/Disabled/Inactive = 0/N/M, save --status/--raw + path --status/--raw
```

## 7. Restore
- Re-enable RCN (step 4 loop, enable) and un-filter setup_env.sh (step 3 restore) when done.

## What "consistent" looks like
- CONTROL (RCN on) completes ~7 min every time.
- REPRO (RCN off) hangs every time, monitor shows the same collapse curve
  (paths -> disabled, cwnd -> 0, qwnd -> 0, MSN stalls). That confirms determinism.
