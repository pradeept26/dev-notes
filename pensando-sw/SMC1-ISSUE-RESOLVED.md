# SMC1 Issue - RESOLVED! ✅

## Status: FIXED

**Date:** 2026-02-25
**Issue:** `/mnt/clusterfs/bringup/` not accessible on SMC1
**Solution:** Host reboot resolved the issue

## What Happened

### Before Reboot
- SSHFS mount existed but was stale
- Error: "Transport endpoint is not connected"
- Init script not accessible

### After Reboot
✅ SSHFS mount came back automatically
✅ systemd mount unit active: `mnt-clusterfs.mount`
✅ Init script accessible: `/mnt/clusterfs/bringup/vulcano_hydra_rccl_bringup.sh`

### Verification Results

**Mount Status:**
```
systest@192.168.66.133:/vol/systest/smc_share on /mnt/clusterfs
type fuse.sshfs (rw,nosuid,nodev,relatime,user_id=1000,group_id=1000)
```

**Init Script:**
```
-rwxr-xr-x 1 ubuntu ubuntu 525 Feb 14 23:35 /mnt/clusterfs/bringup/vulcano_hydra_rccl_bringup.sh
✓ Accessible and executable
```

**Systemd Status:**
```
● mnt-clusterfs.mount - /mnt/clusterfs
     Loaded: loaded (/proc/self/mountinfo)
     Active: active (mounted)
      Where: /mnt/clusterfs
       What: systest@192.168.66.133:/vol/systest/smc_share
```

## Root Cause

The SSHFS mount had become stale (SSH connection lost to systest server).

## Auto-Mount Mechanism

- **Mount Type:** SSHFS (fuse.sshfs)
- **Server:** systest@192.168.66.133:/vol/systest/smc_share
- **Systemd:** Auto-generated mount unit (mnt-clusterfs.mount)
- **Auto-mount:** YES - Comes up after reboot automatically

**Note:** The mount mechanism is auto-configured (not in /etc/fstab, auto-generated systemd unit).

## Lessons Learned

1. **Stale SSHFS mounts** can occur when SSH connection to remote server is lost
2. **Host reboot** restores the SSHFS mount automatically
3. **systemd auto-generates** mount units for active mounts
4. Both SMC1 and SMC2 use this mechanism

## No Action Required

The issue is **resolved** - SMC1 now has working SSHFS mount after reboot.

The init script is accessible and ready to use:
```bash
ssh ubuntu@10.30.75.198
/mnt/clusterfs/bringup/vulcano_hydra_rccl_bringup.sh
```

## Updated Firmware Procedure

Complete firmware update workflow for SMC1:

1. Build firmware
2. Copy to host
3. Update firmware (`nicctl update firmware`)
4. Reset cards (`nicctl reset card --all`)
5. **Run init script:** `/mnt/clusterfs/bringup/vulcano_hydra_rccl_bringup.sh`
6. Verify cards

If cards don't come up:
- Recovery procedure (console checks, SuC reboot, host reboot)
- After host reboot, SSHFS will be mounted automatically
- Init script will be accessible

---
**Status:** ✅ RESOLVED
**Solution:** Host reboot fixed stale SSHFS mount
**No Further Action Needed**
