# Kenya-Perf-4 (kenya-3190) Recovery Procedure

**Date:** 2026-03-03 09:10 AM
**Issue:** Card not detected by host, SSH connection timeout
**Status:** SuC rebooted successfully, need host reboot

---

## Current Status

✅ **Vulcano Console:** Responding (telnet 10.30.52.56 2009)
✅ **SuC Console:** Responding and rebooted (telnet 10.30.52.56 2031)
❌ **Host SSH:** Connection timeout (10.30.52.75:22)
❌ **Card Detection:** Not visible to host

---

## Recovery Steps

### Step 1: SuC Reboot ✅ COMPLETED

The SuC was rebooted via console:
```bash
cd ~/dev-notes/pensando-sw/scripts
./console-mgr.py --setup kenya-3190 --console suc --all reboot \
  --yaml-dir ~/dev-notes/pensando-sw/hardware/vulcano/data
```

### Step 2: Host Reboot ⏳ REQUIRED

Since SSH is not accessible, use BMC to reboot the host:

**Option A: BMC Web Interface**
1. Open browser to: https://10.30.52.74
2. Login: admin/Pen1nfra$
3. Navigate to: Remote Control → Power Control
4. Select: Reset System (graceful reboot)

**Option B: BMC Command Line (if ipmitool available)**
```bash
# Power cycle the host via BMC
ipmitool -I lanplus -H 10.30.52.74 -U admin -P 'Pen1nfra$' power cycle

# Or graceful reset
ipmitool -I lanplus -H 10.30.52.74 -U admin -P 'Pen1nfra$' power reset
```

**Option C: Physical Access**
- Location: SW N2 RU 15-16
- Press reset button or power cycle via APC

**Option D: APC Power Cycle**
```bash
# APC at 10.30.52.55, Port 23
# Login to APC and power cycle port 23
telnet 10.30.52.55
# Login with apc credentials
# Navigate to outlet 23 and cycle power
```

### Step 3: Wait for Host to Come Back Up

```bash
# Wait 2-3 minutes for host to reboot
sleep 180

# Test SSH connectivity
ping -c 3 10.30.52.75
ssh root@10.30.52.75 'hostname; uptime'
```

### Step 4: Verify Card Detection

```bash
# SSH to host
ssh root@10.30.52.75

# Check card status
sudo nicctl show card
sudo nicctl show card -j

# Check firmware version
sudo nicctl show version

# Check RDMA devices
ibv_devices

# Check dmesg for any errors
dmesg | grep -i "pci\|ainic\|vulcano" | tail -50
```

### Step 5: Verify via Console

```bash
# Check version via console
cd ~/dev-notes/pensando-sw/scripts
./console-mgr.py --setup kenya-3190 --console vulcano --all version \
  --yaml-dir ~/dev-notes/pensando-sw/hardware/vulcano/data
```

---

## BMC Access Information

**Kenya-Perf-4 BMC:**
- IP: 10.30.52.74
- User: admin
- Password: Pen1nfra$
- Web: https://10.30.52.74

**APC Access:**
- IP: 10.30.52.55
- Port: 23
- Credentials: apc/apc (typical)

---

## Console Access

**Vulcano Console:**
```bash
telnet 10.30.52.56 2009
# Login as root (no password typically)
```

**SuC Console:**
```bash
telnet 10.30.52.56 2031
# At suc:~$ prompt
```

---

## Expected Outcome

After host reboot:
- Host SSH should be accessible at 10.30.52.75
- Card should show up: `nicctl show card`
- RDMA device should appear: `ibv_devices` (ai0)
- Firmware version: 1.125.0-pi-136 (current)

---

## Next Steps After Recovery

Once the card is detected:
1. Deploy new firmware from branch `hydra_125_1_a`
2. Location: `/sw/ainic_fw_vulcano.tar`
3. Follow standard deployment procedure

---

**Last Updated:** 2026-03-03 09:10 AM
