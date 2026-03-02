# SMC1 NFS Mount Issue - Fix Procedure

## Problem
`/mnt/clusterfs/bringup/` is not available after reboot on SMC1, but works fine on SMC2.

## Root Cause
**UPDATE:** `/etc/fstab` has NO clusterfs entry on BOTH SMC1 and SMC2.

Since SMC2 has `/mnt/clusterfs` available but SMC1 doesn't after reboot, the mount must be:
- Mounted by a systemd service
- Mounted by a startup script
- Mounted by autofs
- Mounted manually on SMC2 but not SMC1

Need to investigate how SMC2 mounts it automatically.

## Fix Procedure

### Step 1: Get NFS Configuration from SMC2 (Working)
```bash
ssh ubuntu@10.30.75.204
# Password: amd123

cat /etc/fstab | grep clusterfs
# Copy this line - you'll need it for SMC1
```

### Step 2: Check SMC1 Current Status
```bash
ssh ubuntu@10.30.75.198
# Password: amd123

# Check if mounted
mount | grep clusterfs
df -h | grep clusterfs

# Check fstab
cat /etc/fstab | grep clusterfs
```

### Step 3: Fix SMC1 fstab
```bash
# On SMC1
sudo cp /etc/fstab /etc/fstab.backup.$(date +%Y%m%d)

# Edit fstab
sudo nano /etc/fstab

# Add the NFS line from SMC2 (from Step 1)
# Should look something like:
# <NFS_SERVER>:/export/path  /mnt/clusterfs  nfs  defaults,_netdev  0  0

# Save and exit
```

### Step 4: Mount and Verify
```bash
# Create mount point if needed
sudo mkdir -p /mnt/clusterfs

# Mount all filesystems from fstab
sudo mount -a

# Verify mount
df -h | grep clusterfs

# Check init script is accessible
ls -l /mnt/clusterfs/bringup/vulcano_hydra_rccl_bringup.sh
```

### Step 5: Reboot Test
```bash
# Reboot to ensure auto-mount works
sudo reboot

# After SMC1 comes back up (2-3 min), SSH and verify
ssh ubuntu@10.30.75.198
df -h | grep clusterfs
ls /mnt/clusterfs/bringup/
```

## Quick Commands

```bash
# 1. Compare fstab entries
echo "=== SMC2 (working) ==="
ssh ubuntu@10.30.75.204 'cat /etc/fstab | grep clusterfs'

echo ""
echo "=== SMC1 (broken) ==="
ssh ubuntu@10.30.75.198 'cat /etc/fstab | grep clusterfs'

# 2. After fixing, verify both
echo "=== SMC1 Mount ==="
ssh ubuntu@10.30.75.198 'df -h | grep clusterfs'

echo "=== SMC2 Mount ==="
ssh ubuntu@10.30.75.204 'df -h | grep clusterfs'
```

## Alternative: Manual Mount Script

If you don't want to use fstab, create a mount script:

```bash
# On SMC1, create /usr/local/bin/mount-clusterfs.sh
sudo nano /usr/local/bin/mount-clusterfs.sh
```

```bash
#!/bin/bash
# mount-clusterfs.sh
mount | grep -q clusterfs || mount -t nfs <NFS_SERVER>:/path /mnt/clusterfs
```

```bash
# Make executable
sudo chmod +x /usr/local/bin/mount-clusterfs.sh

# Add to crontab to run at boot
sudo crontab -e
# Add: @reboot /usr/local/bin/mount-clusterfs.sh
```

## Verification After Fix

```bash
# On SMC1, verify init script works
ssh ubuntu@10.30.75.198
/mnt/clusterfs/bringup/vulcano_hydra_rccl_bringup.sh --help
# Or run it:
/mnt/clusterfs/bringup/vulcano_hydra_rccl_bringup.sh
```

## Status

- [x] Issue identified: /mnt/clusterfs not mounted on SMC1
- [x] Console manager verified working
- [x] Firmware versions verified (both 1.125.1-pi-8)
- [ ] **ACTION REQUIRED:** Get NFS config from SMC2
- [ ] **ACTION REQUIRED:** Add to SMC1 /etc/fstab
- [ ] Test mount
- [ ] Reboot and verify auto-mount
- [ ] Update YAML with actual NFS server details

## SSH Access Note

Automated SSH access requires either:
- SSH keys configured
- Interactive login with password

Tried credentials:
- ubuntu/amd123 - Permission denied (requires interactive/keys)
- root/docker - Permission denied (requires interactive/keys)

**Manual login works fine** - just requires interactive password entry

## Notes

Once fixed, update the YAML with actual NFS server details:
```yaml
setup:
  init_script: /mnt/clusterfs/bringup/vulcano_hydra_rccl_bringup.sh
  nfs_mount:
    path: /mnt/clusterfs
    server: <NFS_SERVER>
    export: /export/path
```

---
Created: 2026-02-25
Status: Pending Fix
