#!/bin/bash
#
# Fix NFS Mount on SMC1
# Copies NFS configuration from SMC2 to SMC1
#

set -e

SMC1_IP="10.30.75.198"
SMC2_IP="10.30.75.204"
USER="ubuntu"
PASS="amd123"

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║  Fixing NFS Mount on SMC1                                     ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

# Check if sshpass is installed
if ! command -v sshpass &> /dev/null; then
    echo "Installing sshpass..."
    sudo apt-get update -qq
    sudo apt-get install -y sshpass
fi

echo "[1/5] Getting NFS config from SMC2 (working setup)..."
NFS_LINE=$(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no ${USER}@${SMC2_IP} 'cat /etc/fstab | grep clusterfs' 2>/dev/null || echo "")

if [ -z "$NFS_LINE" ]; then
    echo "ERROR: Could not get NFS config from SMC2"
    echo "Please check SMC2 manually: ssh ubuntu@10.30.75.204"
    exit 1
fi

echo "  Found NFS entry: $NFS_LINE"
echo ""

echo "[2/5] Checking current SMC1 fstab..."
SMC1_CURRENT=$(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no ${USER}@${SMC1_IP} 'cat /etc/fstab | grep clusterfs' 2>/dev/null || echo "")

if [ -n "$SMC1_CURRENT" ]; then
    echo "  SMC1 already has NFS entry: $SMC1_CURRENT"
    if [ "$SMC1_CURRENT" == "$NFS_LINE" ]; then
        echo "  Entries match - checking if mounted..."
    else
        echo "  Entries differ - will update"
    fi
else
    echo "  No NFS entry found in SMC1 fstab - will add"
fi
echo ""

echo "[3/5] Checking if currently mounted on SMC1..."
MOUNTED=$(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no ${USER}@${SMC1_IP} 'mount | grep clusterfs' 2>/dev/null || echo "")

if [ -n "$MOUNTED" ]; then
    echo "  ✓ Already mounted: $MOUNTED"
    echo "  Checking if init script accessible..."
    INIT_EXISTS=$(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no ${USER}@${SMC1_IP} 'ls /mnt/clusterfs/bringup/vulcano_hydra_rccl_bringup.sh 2>/dev/null && echo EXISTS' || echo "")
    if [ "$INIT_EXISTS" == "EXISTS" ]; then
        echo "  ✓ Init script is accessible - no fix needed!"
        exit 0
    else
        echo "  ! Init script not found - wrong mount path?"
    fi
else
    echo "  Not currently mounted"
fi
echo ""

echo "[4/5] Adding/updating fstab entry on SMC1..."

# Create backup and add entry
sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no ${USER}@${SMC1_IP} << ENDSSH
# Backup fstab
sudo cp /etc/fstab /etc/fstab.backup.\$(date +%Y%m%d_%H%M%S)

# Remove old clusterfs entry if exists
sudo sed -i '/clusterfs/d' /etc/fstab

# Add new entry
echo '$NFS_LINE' | sudo tee -a /etc/fstab

# Show updated fstab
echo "Updated /etc/fstab:"
cat /etc/fstab | grep clusterfs
ENDSSH

echo "  ✓ fstab updated"
echo ""

echo "[5/5] Mounting and verifying..."
sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no ${USER}@${SMC1_IP} << ENDSSH
# Create mount point
sudo mkdir -p /mnt/clusterfs

# Mount
sudo mount -a

# Verify
echo "Mount status:"
df -h | grep clusterfs

echo ""
echo "Checking init script:"
ls -l /mnt/clusterfs/bringup/vulcano_hydra_rccl_bringup.sh
ENDSSH

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║  ✓ NFS Mount Fixed on SMC1!                                   ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""
echo "Next steps:"
echo "  1. Reboot SMC1 to test auto-mount: ssh ubuntu@10.30.75.198 'sudo reboot'"
echo "  2. After reboot, verify: ssh ubuntu@10.30.75.198 'df -h | grep clusterfs'"
echo ""
