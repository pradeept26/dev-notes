---
title: SMC-1/SMC-2 Test Plan — PR #115606 + PCIe QoS Filters
date: 2026-05-12
branch: test-smc-build (based on meta-roce-window-limited-ai + pcie_qos.diff)
cluster: smc1 (10.30.75.198) + smc2 (10.30.75.204)
credentials: root/$SSH_PASS (keyboard-interactive)
asic: vulcano
pipeline: hydra
---

> **Credentials:** This doc uses `$SSH_PASS` (root@smc password) and `$SYSTEST_PASS` (systest@srv3 password) as env vars — set them before running any commands. Do not commit literal passwords.

# SMC-1/SMC-2 Test Plan

## Changes Under Test

### 1. PR #115606: meta_roce path inactivation + window-limited AI
- Tighter path removal: `outstanding_pkts + 1 >= cwnd` (one packet before overshoot)
- Rx-only path re-activation in both exact and overshoot cwnd-enforce modes
- `cwnd_retry_path_removed` bit removed, replaced by `path_removed_tx/rx` toggle
- AI gated on `path_window_limited` flag (snd_nxt_mirror - snd_una >= cwnd)
- New `path_cb3.snd_nxt_mirror` field (halfword-aligned, written by tx_s3)

### 2. PCIe QoS AXI Filters (pcie_qos.diff)
- S4 host table lookup priority: AXI filter on 4 SU INVF ports
  - src id_mask=0xc00, id_match=0x800 (S4 stage source ID)
  - arqos overwrite to 1 (priority)
- PNITR prio_queue_sel=0xc002
- PTD host_max_rd_req_cnt=150 for instances 0,1

## Build

- **Workspace:** /ws/pradeept/ws/usr/src/github.com/pensando/sw-2
- **Branch:** test-smc-build
- **Container:** pradeept_2026-05-12_00.36.04
- **Command:** `make -f Makefile.build build-rudra-vulcano-hydra-ainic-fw`
- **Log:** /tmp/build-vulcano-hydra-hw.log
- **Output:** /sw/nic/buildroot/output/vulcano/ainic_fw_vulcano.tar (inside container)
  - Host path: /ws/pradeept/ws/usr/src/github.com/pensando/sw-2/nic/buildroot/output/vulcano/ainic_fw_vulcano.tar

## host_sw_pkg

From NFS hourly build (not built locally):
```
/vol/builds/hourly/1.125.0-a-232/rudra-bundle/release-artifacts/hydra/vulcano/ainic_bundle_1.125.0-a-232.tar.gz
```
Contains `host_sw_pkg.tar.gz` inside. SCP from srv3.pensando.io using systest/$SYSTEST_PASS.

## Installation Procedure

### Step 1: Copy firmware to nodes
```bash
# Our custom-built firmware
for HOST in 10.30.75.198 10.30.75.204; do
  sshpass -p "$SSH_PASS" scp -o StrictHostKeyChecking=no -o PreferredAuthentications=keyboard-interactive \
    /ws/pradeept/ws/usr/src/github.com/pensando/sw-2/nic/buildroot/output/vulcano/ainic_fw_vulcano.tar \
    root@$HOST:/tmp/
done

# host_sw_pkg from NFS build
for HOST in 10.30.75.198 10.30.75.204; do
  sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o PreferredAuthentications=keyboard-interactive \
    root@$HOST "sshpass -p "$SYSTEST_PASS" scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    systest@srv3.pensando.io:/vol/builds/hourly/1.125.0-a-232/rudra-bundle/release-artifacts/hydra/vulcano/ainic_bundle_1.125.0-a-232.tar.gz /tmp/"
  sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o PreferredAuthentications=keyboard-interactive \
    root@$HOST "cd /tmp && tar xzf ainic_bundle_1.125.0-a-232.tar.gz"
done
```

### Step 2: Flash firmware + reset
```bash
for HOST in 10.30.75.198 10.30.75.204; do
  sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o PreferredAuthentications=keyboard-interactive \
    root@$HOST "cd /tmp && nicctl update firmware -i ainic_fw_vulcano.tar"
  sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o PreferredAuthentications=keyboard-interactive \
    root@$HOST "nicctl reset card --all"
done
```

### Step 3: Install host software
```bash
for HOST in 10.30.75.198 10.30.75.204; do
  sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o PreferredAuthentications=keyboard-interactive \
    root@$HOST "modprobe -r amdgpu; cd /tmp/ainic_bundle_1.125.0-a-232 && tar xzf host_sw_pkg.tar.gz && cd host_sw_pkg && ./install.sh -y; modprobe amdgpu"
done
```

### Step 4: Bringup (on each node)
```bash
for HOST in 10.30.75.198 10.30.75.204; do
  sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o PreferredAuthentications=keyboard-interactive \
    root@$HOST "/mnt/clusterfs/bringup/vulcano_hydra_rccl_bringup.sh"
done
```

Bringup script does:
1. disable_acs.sh
2. roce_device_rename.sh (rename to roce_aiX)
3. qos_cfg_hydra.sh (DSCP 24→prio3 data, DSCP 46→prio2 CTS/ACK, 8 paths, RCN enable, rate-hints 400)
4. modprobe amdgpu
5. 10bit_tags_hydra.py

### Step 5: Verify firmware + basic checks
```bash
for HOST in 10.30.75.198 10.30.75.204; do
  sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o PreferredAuthentications=keyboard-interactive \
    root@$HOST "nicctl show card --detail | grep 'Firmware version' | head -1; ibv_devices | wc -l"
done
```

### Step 6: IB smoke test
```bash
# Server (smc1):
sshpass -p "$SSH_PASS" ssh ... root@10.30.75.198 "ib_write_bw -d roce_ai0 -q 1 -s 8388608 --report_gbits -p 11000 &"
# Client (smc2):
sshpass -p "$SSH_PASS" ssh ... root@10.30.75.204 "ib_write_bw -d roce_ai0 -q 1 -s 8388608 --report_gbits -p 11000 10.30.75.198"
```

### Step 7: RCCL test
```bash
# Run from smc1 (10.30.75.198):
sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o PreferredAuthentications=keyboard-interactive \
  root@10.30.75.198 "cd /mnt/clusterfs/karthik/vulcano/hydra_rccl_scripts && ./run-rccl.sh"
```
- compute_nodes.txt has: 10.30.75.198, 10.30.75.204
- Uses ANP plugin with CTS-disable, RCCL_AINIC_ROCE=1
- NCCL_IB_TC=96 (data DSCP 24<<2), NCCL_IB_FIFO_TC=184 (CTS DSCP 46<<2)
- Default: all_reduce 1K-16G, 20 iterations

### Step 8: Verify PCIe QoS filters
```bash
# On each node, get card UUID first:
CARD_UUID=$(nicctl show card --json | jq -r '.cards[0].id')

# Check filters are programmed:
PAL_CARD_UUID=$CARD_UUID asicmon -f

# Expected: S4 priority filter on SU INVF ports:
#   src id_mask=0xc00, id_match=0x800
#   arqos_overwrite_mask=0xf, arqos_overwrite_value=0x1

# Check filters are hit during traffic (run during ib_write_bw or RCCL):
PAL_CARD_UUID=$CARD_UUID asicmon -f
# Look for non-zero hit counters on the S4 filter entries

# Check PCIe bandwidth (during traffic):
PAL_CARD_UUID=$CARD_UUID asicmon -b

# Check NIC boot log for PTD config:
nicctl show card logs | grep "host_max_rd_req_cnt"
# Expected: "cfg ptd 0: limiting host_max_rd_req_cnt to 150"
#           "cfg ptd 1: limiting host_max_rd_req_cnt to 150"
```

## Discrepancies to Investigate

1. **INVF target mismatch**: Capview pokes use `su0_pics_p4invf` / `su1_pics_p4invf` (PICS INVFs).
   Code uses `SU_CSR_INVF0` / `SU_CSR_INVF1` (channel INVFs). Need to verify which INVF
   S4 host lookups flow through.

2. **Missing PNT axi_attr poke**: Pokes have `pn_pnt_cfg_pnt_axi_attr qos=0x1`, but the diff
   doesn't program this. Is PNITR prio_queue_sel sufficient, or do we need PNT axi_attr too?
