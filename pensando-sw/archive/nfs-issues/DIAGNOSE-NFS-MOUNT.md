# NFS Mount Diagnosis Guide

## Discovery
Both SMC1 and SMC2 have **NO** `/etc/fstab` entry for `/mnt/clusterfs`.

However:
- ✅ SMC2: `/mnt/clusterfs/bringup/` is accessible
- ❌ SMC1: `/mnt/clusterfs/bringup/` is NOT accessible after reboot

**Conclusion:** The mount is being done by some other mechanism on SMC2.

## Investigation Steps

### On SMC2 (Working Setup)

**1. Check if currently mounted:**
```bash
ssh ubuntu@10.30.75.204  # or root@10.30.75.204

# Check mount
mount | grep clusterfs
df -h | grep clusterfs

# This will show:
# - NFS server IP/hostname
# - Export path
# - Mount options
```

**2. Check systemd mount units:**
```bash
# List all mount units
systemctl list-units --type=mount | grep clusterfs

# Check for mount file
ls -la /etc/systemd/system/*clusterfs*
ls -la /lib/systemd/system/*clusterfs*

# If found, show content
systemctl cat mnt-clusterfs.mount
```

**3. Check autofs:**
```bash
# Check if autofs is running
systemctl status autofs

# Check autofs config
cat /etc/auto.master
cat /etc/auto.* | grep clusterfs
```

**4. Check startup scripts:**
```bash
# rc.local
cat /etc/rc.local | grep clusterfs

# cron jobs
sudo crontab -l | grep clusterfs
crontab -l | grep clusterfs

# systemd services
systemctl list-unit-files | grep mount
```

**5. Check init scripts or custom services:**
```bash
# Look for mount scripts
find /etc/init.d/ -type f -exec grep -l clusterfs {} \;
find /usr/local/bin/ -type f -exec grep -l clusterfs {} \;

# Check for custom systemd services
ls /etc/systemd/system/*.service | xargs grep -l clusterfs
```

**6. Get complete mount information:**
```bash
# On SMC2, get full mount details
mount | grep clusterfs

# Example output:
# <NFS_SERVER>:/export/path on /mnt/clusterfs type nfs (rw,...)
#
# Note down:
# - NFS_SERVER: IP or hostname
# - Export path: /export/path
# - Mount options: rw, etc.
```

### On SMC1 (Broken Setup)

**Run same checks to see what's different:**
```bash
ssh ubuntu@10.30.75.198  # or root@10.30.75.198

# Check if mounted
mount | grep clusterfs
# Expected: Nothing (not mounted)

# Check systemd
systemctl list-units --type=mount | grep clusterfs

# Check autofs
systemctl status autofs

# Compare with SMC2 findings
```

## Once You Find How SMC2 Mounts It

### If it's a systemd mount unit:
```bash
# On SMC2, get the unit file
systemctl cat mnt-clusterfs.mount > /tmp/clusterfs.mount

# Copy to SMC1
scp /tmp/clusterfs.mount root@10.30.75.198:/etc/systemd/system/

# On SMC1
systemctl daemon-reload
systemctl enable mnt-clusterfs.mount
systemctl start mnt-clusterfs.mount
```

### If it's autofs:
```bash
# Copy autofs config from SMC2 to SMC1
# Then enable autofs on SMC1
```

### If it's a startup script:
```bash
# Copy the script from SMC2 to SMC1
# Enable it (systemd, cron, rc.local, etc.)
```

### If it's manual and you want automatic:

**Option A: Add to /etc/fstab (recommended)**
```bash
# On SMC1
sudo nano /etc/fstab

# Add line (use details from SMC2 mount command):
<NFS_SERVER>:/export/path  /mnt/clusterfs  nfs  defaults,_netdev  0  0

# Mount
sudo mkdir -p /mnt/clusterfs
sudo mount -a

# Test
ls /mnt/clusterfs/bringup/
```

**Option B: Create systemd mount unit**
```bash
# Create /etc/systemd/system/mnt-clusterfs.mount
sudo nano /etc/systemd/system/mnt-clusterfs.mount
```

```ini
[Unit]
Description=Mount clusterfs NFS share
After=network-online.target
Wants=network-online.target

[Mount]
What=<NFS_SERVER>:/export/path
Where=/mnt/clusterfs
Type=nfs
Options=defaults,_netdev

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable mnt-clusterfs.mount
sudo systemctl start mnt-clusterfs.mount
```

**Option C: Startup script**
```bash
# Create /usr/local/bin/mount-clusterfs.sh
sudo nano /usr/local/bin/mount-clusterfs.sh
```

```bash
#!/bin/bash
mount | grep -q clusterfs || mount -t nfs <NFS_SERVER>:/path /mnt/clusterfs
```

```bash
sudo chmod +x /usr/local/bin/mount-clusterfs.sh

# Add to crontab
sudo crontab -e
# Add: @reboot sleep 30 && /usr/local/bin/mount-clusterfs.sh
```

## Quick Diagnostic Commands

Run these on SMC2 to find the answer:

```bash
ssh ubuntu@10.30.75.204  # Interactive login

# Get mount details
mount | grep clusterfs | tee /tmp/nfs-mount-info.txt

# Check all possible mount mechanisms
systemctl list-units --type=mount | grep clusterfs
systemctl status autofs
sudo crontab -l | grep -i mount
cat /etc/rc.local 2>/dev/null | grep -i mount
ls /etc/systemd/system/*.mount 2>/dev/null

# Search for mount scripts
sudo grep -r "mount.*clusterfs" /etc/ 2>/dev/null
sudo grep -r "mount.*clusterfs" /usr/local/ 2>/dev/null
```

## Expected Outcome

After investigation, you'll find:
1. How SMC2 mounts `/mnt/clusterfs` automatically
2. The NFS server and export path
3. Can replicate the same mechanism on SMC1
4. Both setups will have persistent NFS mount

---
**Status:** Needs manual investigation on SMC2
**Action:** Find how SMC2 auto-mounts, replicate on SMC1
