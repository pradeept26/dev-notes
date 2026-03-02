# ACTION NEEDED: Fix SMC1 NFS Mount

## Quick Investigation Checklist

When you return, run these commands to diagnose:

### On SMC2 (Working)
```bash
ssh ubuntu@10.30.75.204
# Password: amd123

# 1. Check current mount
mount | grep clusterfs

# 2. Check systemd mounts
systemctl list-units --type=mount | grep clusterfs

# 3. Check autofs
systemctl status autofs
cat /etc/auto.master 2>/dev/null | grep clusterfs

# 4. Check startup scripts
cat /etc/rc.local 2>/dev/null | grep mount
sudo crontab -l 2>/dev/null | grep mount
crontab -l 2>/dev/null | grep mount

# 5. Search for mount scripts
sudo find /usr/local -name "*mount*" -o -name "*nfs*" 2>/dev/null
```

### On SMC1 (Broken)
```bash
ssh ubuntu@10.30.75.198
# Password: amd123

# Run same commands as SMC2
# Compare differences
```

## Once You Find the Mount Method

**Copy from SMC2 to SMC1:**

### If systemd mount unit:
```bash
# On SMC2
systemctl cat mnt-clusterfs.mount > /tmp/clusterfs.mount

# Copy to SMC1
scp /tmp/clusterfs.mount ubuntu@10.30.75.198:/tmp/

# On SMC1
sudo cp /tmp/clusterfs.mount /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable mnt-clusterfs.mount
sudo systemctl start mnt-clusterfs.mount
```

### If startup script:
```bash
# Find the script on SMC2, copy to SMC1
# Enable on SMC1
```

### If manual mount, add to fstab:
```bash
# On SMC1
sudo nano /etc/fstab

# Add (use NFS server from SMC2 mount command):
<NFS_SERVER>:/export/path  /mnt/clusterfs  nfs  defaults,_netdev  0  0

# Mount
sudo mount -a
```

## Quick Fix to Get Going

**Temporary Solution (until you figure out auto-mount):**

```bash
# On SMC1, manually mount before running init script
ssh ubuntu@10.30.75.198

# Get NFS server from SMC2 first!
# Then mount manually:
sudo mkdir -p /mnt/clusterfs
sudo mount -t nfs <NFS_SERVER>:/export/path /mnt/clusterfs

# Run init script
/mnt/clusterfs/bringup/vulcano_hydra_rccl_bringup.sh
```

## Expected Output from SMC2

When you run `mount | grep clusterfs` on SMC2, you should see something like:

```
10.30.64.100:/export/bringup on /mnt/clusterfs type nfs4 (rw,relatime,...)
```

Or:
```
nas-server:/shared/pensando on /mnt/clusterfs type nfs (rw,...)
```

**This will tell you:**
- NFS server IP/hostname
- Export path
- NFS version
- Mount options

## After Fix

Update the YAML files with NFS details:

```yaml
setup:
  init_script: /mnt/clusterfs/bringup/vulcano_hydra_rccl_bringup.sh
  nfs_mount:
    enabled: true
    path: /mnt/clusterfs
    server: <NFS_SERVER>
    export: /export/path
    mount_method: systemd  # or fstab, autofs, manual
```

---
**Priority:** Medium (blocks init script after reboot)
**Time Estimate:** 10-15 minutes to investigate and fix
**Status:** Waiting for manual investigation
