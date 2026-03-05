# ✅ Firmware Deployment SUCCESS - Kenya-Perf-3 and Kenya-Perf-4

**Date:** 2026-03-03
**Branch:** hydra_125_1_a
**Deployment Status:** ✅ **COMPLETE AND VERIFIED**

---

## Deployment Summary

### Build Details
- **Build time:** 2 minutes 56 seconds
- **Firmware size:** 7.5M
- **Build location:** `/sw/ainic_fw_vulcano.tar`

### Deployment Results

**Kenya-Perf-3 (kenya-1354) - 10.30.52.66** ✅
- **Old firmware:** 1.125.0-pi-136 (Feb 28 2026 20:20:05)
- **New firmware:** 1.125.1-pi-8 (Mar 3 2026 00:58:28)
- **Build tag:** 1.XX.0-C-8-50615-g8573c4248f66
- **Partition:** mainfwb (switched from mainfwa)
- **Card status:** Detected and running
- **RDMA device:** rocep198s0 (working)

**Kenya-Perf-4 (kenya-3190) - 10.30.52.75** ✅
- **Old firmware:** 1.125.0-pi-136 (Feb 28 2026 20:20:05)
- **New firmware:** 1.125.1-pi-8 (Mar 3 2026 00:58:28)
- **Build tag:** 1.XX.0-C-8-50615-g8573c4248f66
- **Partition:** mainfwb (switched from mainfwa)
- **Card status:** Detected and running
- **RDMA device:** rocep198s0 (working)

---

## Timeline

| Time | Event |
|------|-------|
| 08:45 | Tmux session created |
| 08:47 | Git submodules updated |
| 08:47 | Docker launched |
| 08:47-08:52 | Assets pulled (5min 33sec) |
| 08:52 | Build cleaned |
| 08:56-08:59 | Firmware built (2min 56sec) |
| 09:05 | Pre-deployment status checked via console |
| 09:54 | Firmware copied to both hosts |
| 09:54-09:59 | Firmware updated in parallel (~5 min each) |
| 09:59 | Cards reset |
| 10:00 | SuC rebooted |
| 10:00 | Hosts rebooted |
| 10:03 | Both hosts verified working |

**Total time:** ~1 hour 18 minutes (including all steps)
**Actual build time:** 2 minutes 56 seconds
**Deployment time (parallel):** ~5 minutes per host

---

## Verification Results

### Both Hosts Confirmed Working

**Card Detection:**
- Kenya-Perf-3: Card detected (42424650-5232-3630-3530-303430000000, PCIe 0000:c1:00.0)
- Kenya-Perf-4: Card detected (42424650-5232-3630-3530-303143000000, PCIe 0000:c1:00.0)

**Firmware Version:**
- Version: 1.125.1-pi-8
- Build time: Mar 3 2026 00:58:28
- Build tag: 1.XX.0-C-8-50615-g8573c4248f66
- Pipeline: rudra
- P4 program: hydra

**RDMA Devices:**
- Both hosts: rocep198s0 device available

**Firmware Partition:**
- Switched from mainfwa → mainfwb (alternate partition)

---

## Key Commands Used

### Build Workflow
```bash
# 1. Tmux session
tmux new-session -s pensando-sw

# 2. Git submodules
git submodule update --init --recursive

# 3. Docker cleanup & launch
docker ps -a | grep "$(whoami)_" | awk '{print $1}' | xargs -r docker stop | xargs -r docker rm
cd nic && make docker/shell

# 4. Inside Docker
cd /sw && make pull-assets
make -f Makefile.ainic clean
make -f Makefile.build build-rudra-vulcano-hydra-ainic-fw
```

### Deployment (Parallel)
```bash
# Copy firmware from Docker to host
docker cp <container_id>:/sw/ainic_fw_vulcano.tar /tmp/

# Deploy to both hosts in parallel
scp /tmp/ainic_fw_vulcano.tar root@10.30.52.66:/tmp/
scp /tmp/ainic_fw_vulcano.tar root@10.30.52.75:/tmp/
sudo nicctl update firmware -i /tmp/ainic_fw_vulcano.tar
sudo nicctl reset card --all
```

### Recovery
```bash
# SuC reboot via console
cd ~/dev-notes/pensando-sw/scripts
./console-mgr.py --setup kenya-1354 --console suc --all reboot --yaml-dir ~/dev-notes/pensando-sw/hardware/vulcano/data
./console-mgr.py --setup kenya-3190 --console suc --all reboot --yaml-dir ~/dev-notes/pensando-sw/hardware/vulcano/data

# Host reboot
ssh root@10.30.52.66 'sudo reboot'
ssh root@10.30.52.75 'sudo reboot'
```

### Verification
```bash
# Via console
./console-mgr.py --setup kenya-1354 --console vulcano --all version --yaml-dir ~/dev-notes/pensando-sw/hardware/vulcano/data
./console-mgr.py --setup kenya-3190 --console vulcano --all version --yaml-dir ~/dev-notes/pensando-sw/hardware/vulcano/data

# Via SSH
ssh root@10.30.52.66 'sudo nicctl show card'
ssh root@10.30.52.75 'sudo nicctl show card'
```

---

## Documentation & Scripts Created

1. **Build helper:** `~/dev-notes/pensando-sw/scripts/build-hydra.sh`
2. **Deployment guide:** `~/dev-notes/pensando-sw/hydra_125_1_a-firmware-deployment-20260303.md`
3. **Status report:** `~/dev-notes/pensando-sw/kenya-perf-current-status.md`
4. **Recovery guide:** `~/dev-notes/pensando-sw/kenya-perf-4-recovery.md`
5. **Deployment logs:** `/tmp/deploy_kenya-perf-3.log`, `/tmp/deploy_kenya-perf-4.log`

---

## Notes

- **Parallel deployment:** Both hosts updated simultaneously (efficient!)
- **Recovery required:** Standard post-firmware-update recovery (SuC + host reboot)
- **Tmux session:** `pensando-sw` session preserved with Docker container inside
- **Firmware partition:** Successfully switched from A → B partition
- **Both hosts:** Running new firmware from branch `hydra_125_1_a`

---

## Success Criteria Met

✅ Firmware built successfully
✅ Firmware deployed to kenya-perf-3
✅ Firmware deployed to kenya-perf-4
✅ Cards detected on both hosts
✅ RDMA devices available on both hosts
✅ Firmware version verified via console
✅ Both hosts operational

---

**Deployment Status:** ✅ **100% SUCCESSFUL**

**Last Updated:** 2026-03-03 10:03 AM
