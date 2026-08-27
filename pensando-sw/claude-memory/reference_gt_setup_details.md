---
name: GT Vulcano multiplane testbed setup details
description: GT-1/GT-4 setup specifics — lane mapping, GID index, ROCm, switch config, ionic_rdma
type: reference
originSessionId: 2431faa0-7c48-4a10-a709-cb3f6bf2249b
---
**Testbed:** GT-1 (10.30.69.101) + GT-4 (10.30.69.98), root/docker
**Switches:** leaf1 (10.30.69.196), leaf2 (10.30.69.92), admin/Micas123
**Benchmark dir:** `/home/amd/vul-rccl-benchmark/` on GT-1

## Lane mapping (CRITICAL — differs between FW versions)

| FW | MAC channels | Switch ports |
|---|---|---|
| 1.130.5-a (sequential) | 48,16,0,32 for ports 1,3,5,7 | Ethernet0,1,2,3 |
| 1.130.2-a (alternate) | 48,16,48,16 — duplicate! | Ethernet0,2,4,6 |

Moving between builds requires switch reconfiguration. 5-a backup on both leaves: `/etc/sonic/config_db_5a_backup.json`

## GID index

| FW | IPv6 VIP GID index | run-rccl.sh setting |
|---|---|---|
| 1.130.5-a-7 / Nataraj's reverted | GID[1] | `NCCL_IB_GID_INDEX=1` |
| 1.130.2-a-11, 1.130.5-a-13 | GID[2] | `NCCL_IB_GID_INDEX=2` |

## ROCm versions

Both ROCm 7.0.2 and 10.1 installed. Check current: `readlink /opt/rocm`

Switch to 7.0.2:
```bash
ln -sfn /opt/rocm-7.0.2 /opt/rocm  # both GT-1 and GT-4
sed -i 's/RCCL_RELEASE=.*:-10.1/RCCL_RELEASE=${RELEASE:-7.0.2}/' ~/vul-rccl-benchmark/setup_env.sh
```

Remove ROCm 10.1-only vars from run-rccl.sh: `NCCL_NET=ROCM-IB`, `NCCL_GIN_ENABLE=0`, `RCCL_CTS_OFFLOAD_ENABLED=0`, `RCCL_MULTIPLANE_MAP_FILE=*.xml`
Use: `NCCL_NET_PLUGIN=librccl-anp.so`, `RCCL_VIP_PIP_MAP_FILE=*.json`

## ionic_rdma on GT-1

Missing from kernel module path after card reset. Fix:
```bash
depmod -a && modprobe ionic_rdma
# Or: dnf install -y /tmp/ainic_bundle_*/host_sw_pkg/ionic_driver/rpm/el9/ionic-dkms-*.el9.noarch.rpm
bash ~/vul-rccl-benchmark/gt_node1_rename_mp_roce.sh  # rename RDMA devices
```

## RCCL run procedure

```bash
# Setup (after card reset/FW change)
bash setup.sh && bash setup.sh  # run twice
bash check_ipv6_connectivity.sh  # expect 40/40

# Run all collectives
python3 run.py --runs 5 --output <dirname>

# Quick sanity
./run-rccl.sh alltoall 1G 1G 100
```

## Reports on srv20

- `http://srv20.pensando.io/ainic/rccl_data/report_1.130.5-a-13_rocm7_rcn.html`
- `http://srv20.pensando.io/ainic/rccl_data/comparison_1.130.5-a-13_vs_1.130.2-a-11_rocm7_rcn.html`
