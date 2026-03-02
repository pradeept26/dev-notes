#!/bin/bash
#
# Check NFS Mount Status on SMC Setups
# Helps diagnose why /mnt/clusterfs is not available after reboot
#

cat << 'EOF'
╔═══════════════════════════════════════════════════════════════════════╗
║  NFS Mount Troubleshooting for /mnt/clusterfs                        ║
╚═══════════════════════════════════════════════════════════════════════╝

ISSUE: /mnt/clusterfs/bringup/ not available after reboot on SMC1
       (but works on SMC2)

LIKELY CAUSES:
--------------
1. Missing /etc/fstab entry on SMC1
2. NFS server not reachable
3. Mount options incorrect
4. NFS services not started

DIAGNOSIS STEPS:
----------------

Step 1: Check if currently mounted
-----------------------------------
ssh ubuntu@10.30.75.198
mount | grep clusterfs
df -h | grep clusterfs

Expected: Should show NFS mount
If missing: NFS is not mounted

Step 2: Check /etc/fstab
------------------------
cat /etc/fstab | grep clusterfs

Expected on SMC2 (working):
<NFS_SERVER>:/path  /mnt/clusterfs  nfs  defaults,_netdev  0  0

Compare with SMC1:
- If entry missing → Add to /etc/fstab
- If entry present but different → Fix options

Step 3: Check NFS server accessibility
---------------------------------------
# Find NFS server from SMC2
ssh ubuntu@10.30.75.204 'cat /etc/fstab | grep clusterfs'
# Note the NFS server IP/hostname

# Test from SMC1
ping <NFS_SERVER>
showmount -e <NFS_SERVER>

Step 4: Manual mount test
--------------------------
ssh ubuntu@10.30.75.198

# Create mount point if needed
sudo mkdir -p /mnt/clusterfs

# Try manual mount (use server from SMC2 fstab)
sudo mount -t nfs <NFS_SERVER>:/path /mnt/clusterfs

# If successful
ls /mnt/clusterfs/bringup/

Step 5: Fix permanently
-----------------------
# If manual mount works, add to /etc/fstab on SMC1

# Get exact fstab line from SMC2
ssh ubuntu@10.30.75.204 'cat /etc/fstab | grep clusterfs'

# Add same line to SMC1 /etc/fstab
ssh ubuntu@10.30.75.198
sudo nano /etc/fstab
# Add the line from SMC2

# Test fstab mount
sudo mount -a

# Verify
df -h | grep clusterfs

# Reboot test
sudo reboot
# After reboot:
df -h | grep clusterfs  # Should be mounted

QUICK FIX COMMANDS:
-------------------

# 1. Get NFS config from SMC2
echo "=== SMC2 NFS Config ==="
ssh ubuntu@10.30.75.204 'cat /etc/fstab | grep clusterfs'

# 2. Copy to SMC1 (manual step - edit /etc/fstab)
echo ""
echo "=== Add this line to SMC1 /etc/fstab ==="
echo "Then run: sudo mount -a"

# 3. Verify after adding
echo ""
echo "=== Verify on SMC1 ==="
echo "ssh ubuntu@10.30.75.198 'df -h | grep clusterfs'"

ALTERNATIVE: Auto-mount script
-------------------------------
# If fstab is not desired, create systemd service to mount after boot
# Or add to rc.local / startup scripts

WACO SETUPS:
------------
Note: Waco setups also use NFS mount at /mnt/clusterfs
Check if they have similar issues

EOF
