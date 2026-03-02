# Firmware Update Quick Reference

Quick reference for updating Vulcano firmware on hardware setups.

## 🚀 Quick Start (One-liner per setup)

```bash
# SMC1
scp /sw/ainic_fw_vulcano.tar ubuntu@10.30.75.198:/tmp/ && ssh ubuntu@10.30.75.198 'sudo nicctl update firmware -i /tmp/ainic_fw_vulcano.tar && sudo nicctl reset card --all'

# SMC2
scp /sw/ainic_fw_vulcano.tar ubuntu@10.30.75.204:/tmp/ && ssh ubuntu@10.30.75.204 'sudo nicctl update firmware -i /tmp/ainic_fw_vulcano.tar && sudo nicctl reset card --all'

# GT1
scp /sw/ainic_fw_vulcano.tar root@10.30.69.101:/tmp/ && ssh root@10.30.69.101 'nicctl update firmware -i /tmp/ainic_fw_vulcano.tar && nicctl reset card --all'

# GT4
scp /sw/ainic_fw_vulcano.tar root@10.30.69.98:/tmp/ && ssh root@10.30.69.98 'nicctl update firmware -i /tmp/ainic_fw_vulcano.tar && nicctl reset card --all'

# Waco5
scp /sw/ainic_fw_vulcano.tar ubuntu@10.30.64.25:/tmp/ && ssh ubuntu@10.30.64.25 'sudo nicctl update firmware -i /tmp/ainic_fw_vulcano.tar && sudo nicctl reset card --all'

# Waco6
scp /sw/ainic_fw_vulcano.tar ubuntu@10.30.64.26:/tmp/ && ssh ubuntu@10.30.64.26 'sudo nicctl update firmware -i /tmp/ainic_fw_vulcano.tar && sudo nicctl reset card --all'
```

## 📋 Step-by-Step Process

### 1. Build Firmware
```bash
# Inside Docker at /sw
make -f Makefile.build build-rudra-vulcano-hydra-ainic-fw
# Output: /sw/ainic_fw_vulcano.tar
```

### 2. Copy to Host
```bash
scp /sw/ainic_fw_vulcano.tar <user>@<host_ip>:/tmp/
```

### 3. Update Firmware (on host)
```bash
sudo nicctl update firmware -i /tmp/ainic_fw_vulcano.tar
# Takes 3-5 minutes, shows progress
```

### 4. Reset Cards
```bash
sudo nicctl reset card --all
# Activates new firmware on next boot
```

### 5. Run Init Script
```bash
# IMPORTANT: Run setup-specific init script
# SMC1/SMC2:
/mnt/clusterfs/bringup/vulcano_hydra_rccl_bringup.sh

# Check YAML for other setups:
# yq '.setup.init_script' ~/dev-notes/pensando-sw/hardware/vulcano/data/<setup>.yml
```

### 6. Verify
```bash
sudo nicctl show card          # Should show all 8 cards
sudo nicctl show version       # Check firmware version
ibv_devices                    # Should show ai0-ai7
```

## 🔧 Using Helper Script

```bash
# Automated update using YAML data
cd ~/dev-notes/pensando-sw/scripts
./update-firmware.sh smc1 /sw/ainic_fw_vulcano.tar
./update-firmware.sh waco5 /sw/ainic_fw_vulcano.tar

# The script will:
# 1. Read setup info from YAML
# 2. Copy firmware
# 3. Update firmware
# 4. Reset cards
# 5. Verify all cards are up
```

## 📊 Setup Information Quick Reference

| Setup | IP | User | Password | NICs |
|-------|------|------|----------|------|
| SMC1 | 10.30.75.198 | ubuntu | amd123 | 8 |
| SMC2 | 10.30.75.204 | ubuntu | amd123 | 8 |
| GT1 | 10.30.69.101 | root | docker | 8 |
| GT4 | 10.30.69.98 | root | docker | 8 |
| Waco5 | 10.30.64.25 | ubuntu | amd123 | 8 |
| Waco6 | 10.30.64.26 | ubuntu | amd123 | 8 |

## 🛠️ nicctl Command Reference

```bash
# Firmware management
nicctl update firmware -i <tar_file>   # Update firmware (3-5 min)
nicctl show version                    # Show current version
nicctl show version -j                 # JSON format

# Card management
nicctl show card                       # Show all cards status
nicctl show card -j                    # JSON format
nicctl reset card --all                # Reset all cards
nicctl reset card <id>                 # Reset specific card

# Interface management
nicctl show lif                        # Show logical interfaces
nicctl show lif -j | grep enp          # Filter network interfaces

# Debug
nicctl techsupport <file>              # Collect debug data
```

## 🔍 Verification Commands

```bash
# Check all cards are detected (should be 8)
lspci | grep Pensando | wc -l

# Check RDMA devices (should show ai0-ai7)
ibv_devices

# Check network interfaces (should show benic1p1-benic8p1)
ip link show | grep benic

# Get detailed card info
nicctl show card -j | jq .

# Check firmware version on all cards
nicctl show version -j | jq .
```

## ⚠️ Troubleshooting - Cards Not Coming Up

**Common Issue:** After firmware update and card reset, not all cards may come up.

### Recovery Procedure (5 Steps)

**1. Verify firmware version on Vulcano consoles**
```bash
cd ~/dev-notes/pensando-sw/scripts
./console-mgr.py --setup smc1 --console vulcano --all version
# Confirms firmware actually updated on each NIC
```

**2. Reboot Vulcano via SuC consoles**
```bash
./console-mgr.py --setup smc1 --console suc --all reboot
# Executes "kernel reboot" on all SuC consoles
```

**3. Reboot the host**
```bash
ssh ubuntu@10.30.75.198 'sudo reboot'
# Or use BMC if needed:
# ipmitool -I lanplus -H 10.30.69.47 -U admin -P 'PenInfra$' power cycle
```

**4. Wait for host to come back**
```bash
# Wait 2-3 minutes
sleep 120

# Test SSH
ssh ubuntu@10.30.75.198 'uptime'
```

**5. Verify all cards**
```bash
ssh ubuntu@10.30.75.198 'sudo nicctl show card'
# Should show all 8 cards now
```

### Complete Recovery One-liner

```bash
# Full recovery workflow (replace smc1 with your setup)
cd ~/dev-notes/pensando-sw/scripts && \
./console-mgr.py --setup smc1 --console vulcano --all version && \
./console-mgr.py --setup smc1 --console suc --all reboot && \
ssh ubuntu@10.30.75.198 'sudo reboot' && \
sleep 120 && \
ssh ubuntu@10.30.75.198 'sudo nicctl show card'
```

### Per-Setup Recovery Commands

```bash
# SMC1
cd ~/dev-notes/pensando-sw/scripts && \
./console-mgr.py --setup smc1 --console suc --all reboot && \
ssh ubuntu@10.30.75.198 'sudo reboot'

# SMC2
cd ~/dev-notes/pensando-sw/scripts && \
./console-mgr.py --setup smc2 --console suc --all reboot && \
ssh ubuntu@10.30.75.204 'sudo reboot'

# Waco5
cd ~/dev-notes/pensando-sw/scripts && \
./console-mgr.py --setup waco5 --console suc --all reboot && \
ssh ubuntu@10.30.64.25 'sudo reboot'

# GT1 (different credentials!)
cd ~/dev-notes/pensando-sw/scripts && \
./console-mgr.py --setup gt1 --console suc --all reboot && \
ssh root@10.30.69.101 'reboot'
```

### Additional Debugging

```bash
# Check PCIe devices
lspci | grep Pensando | wc -l

# Rescan PCIe bus
echo 1 | sudo tee /sys/bus/pci/rescan

# Check kernel logs
dmesg | tail -100
journalctl -xe | grep -i pensando

# Collect techsupport
nicctl techsupport /tmp/techsupport_$(date +%Y%m%d_%H%M%S).tar.gz
```

## 📁 File Locations

- **Firmware builds:** `/sw/ainic_fw_vulcano.tar` (in Docker)
- **Setup configs:** `~/dev-notes/pensando-sw/hardware/vulcano/data/*.yml`
- **Full docs:** `~/dev-notes/pensando-sw/context.md`
- **nicctl source:** `nic/infra/ainic/nicctl/`

## 🔄 Bulk Updates

**Update all SMC setups:**
```bash
for host in 10.30.75.198 10.30.75.204; do
  echo "Updating $host..."
  scp /sw/ainic_fw_vulcano.tar ubuntu@$host:/tmp/
  ssh ubuntu@$host 'sudo nicctl update firmware -i /tmp/ainic_fw_vulcano.tar && sudo nicctl reset card --all'
done
```

**Update all Waco setups:**
```bash
for host in 10.30.64.25 10.30.64.26; do
  echo "Updating $host..."
  scp /sw/ainic_fw_vulcano.tar ubuntu@$host:/tmp/
  ssh ubuntu@$host 'sudo nicctl update firmware -i /tmp/ainic_fw_vulcano.tar && sudo nicctl reset card --all'
done
```

---

For detailed procedures, see:
- `~/dev-notes/pensando-sw/context.md` - Complete workflow
- `~/dev-notes/pensando-sw/hardware/vulcano/<setup>.md` - Setup-specific guides
