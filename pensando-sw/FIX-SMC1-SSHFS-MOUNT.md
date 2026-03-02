# SMC1 SSHFS Mount Fix - SOLVED!

## ✅ Root Cause Found

**Mount Type:** SSHFS (not NFS!)
**Server:** systest@192.168.66.133:/vol/systest/smc_share
**Mount Point:** /mnt/clusterfs

### Current Status

**SMC2 (Working):**
```
systest@192.168.66.133:/vol/systest/smc_share on /mnt/clusterfs
type fuse.sshfs (rw,nosuid,nodev,relatime,user_id=0,group_id=0)
✓ Connected and accessible
```

**SMC1 (Broken):**
```
systest@192.168.66.133:/vol/systest/smc_share on /mnt/clusterfs
type fuse.sshfs (rw,nosuid,nodev,relatime,user_id=1000,group_id=1000)
✗ Transport endpoint is not connected (stale mount)
```

**Issue:** SMC1's SSHFS mount is stale - the SSH connection to systest server was lost.

## Quick Fix (Immediate - Run This)

```bash
ssh ubuntu@10.30.75.198
# Password: amd123

# 1. Unmount stale SSHFS
sudo umount -l /mnt/clusterfs

# 2. Remount (will ask for systest password)
sudo sshfs -o allow_other,default_permissions systest@192.168.66.133:/vol/systest/smc_share /mnt/clusterfs
# Enter password for systest@192.168.66.133

# 3. Verify
ls /mnt/clusterfs/bringup/
ls /mnt/clusterfs/bringup/vulcano_hydra_rccl_bringup.sh

# 4. Test init script
/mnt/clusterfs/bringup/vulcano_hydra_rccl_bringup.sh
```

## Permanent Fix (Auto-Remount After Reboot)

### Step 1: Set Up SSH Keys (On Both SMC1 and SMC2)

```bash
# On SMC1
ssh ubuntu@10.30.75.198

# Generate SSH key for root
sudo ssh-keygen -t rsa -f /root/.ssh/id_rsa -N ""

# Copy key to systest server
sudo ssh-copy-id -i /root/.ssh/id_rsa systest@192.168.66.133
# Enter systest password when prompted

# Test passwordless SSH
sudo ssh -i /root/.ssh/id_rsa systest@192.168.66.133 ls /vol/systest/smc_share
```

### Step 2: Add to /etc/fstab

```bash
# On SMC1
sudo nano /etc/fstab

# Add this line at the end:
systest@192.168.66.133:/vol/systest/smc_share /mnt/clusterfs fuse.sshfs defaults,_netdev,allow_other,default_permissions,IdentityFile=/root/.ssh/id_rsa 0 0

# Save and exit
```

### Step 3: Test Mount

```bash
# Unmount current (stale) mount
sudo umount -l /mnt/clusterfs

# Mount using fstab
sudo mount -a

# Verify
df -h | grep clusterfs
ls /mnt/clusterfs/bringup/
```

### Step 4: Reboot Test

```bash
sudo reboot

# After reboot (2-3 min), SSH back
ssh ubuntu@10.30.75.198

# Verify auto-mounted
df -h | grep clusterfs
ls /mnt/clusterfs/bringup/vulcano_hydra_rccl_bringup.sh
```

## Do the Same for SMC2

SMC2 is currently working but will also break after reboot. Apply same fix:

```bash
ssh ubuntu@10.30.75.204
# Set up SSH keys
# Add to /etc/fstab
# Test
```

## Alternative: Systemd Mount Unit

If you prefer systemd over fstab:

```bash
# Create /etc/systemd/system/mnt-clusterfs.mount
sudo nano /etc/systemd/system/mnt-clusterfs.mount
```

```ini
[Unit]
Description=Mount clusterfs via SSHFS
After=network-online.target
Wants=network-online.target

[Mount]
What=systest@192.168.66.133:/vol/systest/smc_share
Where=/mnt/clusterfs
Type=fuse.sshfs
Options=_netdev,allow_other,default_permissions,IdentityFile=/root/.ssh/id_rsa

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable mnt-clusterfs.mount
sudo systemctl start mnt-clusterfs.mount
sudo systemctl status mnt-clusterfs.mount
```

## Summary

**Problem:** Stale SSHFS mount on SMC1
**Cause:** SSH connection to systest@192.168.66.133 lost
**Quick Fix:** `sudo umount -l /mnt/clusterfs && sudo sshfs ... (remount)`
**Permanent Fix:** Set up SSH keys + add to /etc/fstab
**Applies to:** Both SMC1 and SMC2 (both will break after reboot)

---
**Status:** ✅ Diagnosed and fix procedure ready
**Server:** systest@192.168.66.133:/vol/systest/smc_share
**Action:** Set up SSH keys and fstab on both SMCs
