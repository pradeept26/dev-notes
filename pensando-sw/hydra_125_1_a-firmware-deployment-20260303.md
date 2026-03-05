# Hydra Vulcano Firmware Build & Deployment Summary

**Date:** 2026-03-03
**Branch:** hydra_125_1_a
**Build Status:** ✅ **COMPLETED SUCCESSFULLY**

---

## Build Completion

**Build Time:** 2 minutes 56 seconds (much faster than expected!)

**Output Files:**
```
-rw-r--r-- 1 pradeept pradeept 7.5M Mar  3 00:59 /sw/ainic_fw_vulcano.tar
-rw-r--r-- 1 pradeept pradeept 7.6M Mar  3 00:59 /sw/ainic_fw_vulcano.pldmfw
```

**Location:** Inside Docker at `/sw/`
- **Primary file for deployment:** `/sw/ainic_fw_vulcano.tar`
- **Alternative (PLDM format):** `/sw/ainic_fw_vulcano.pldmfw`

---

## Target Hosts for Deployment

### Kenya-Perf-3 (kenya-1354)
- **IP:** 10.30.52.66
- **Credentials:** root/docker
- **Card:** Saraceno (single card, 32GB memory)
- **Current User:** Sunil Akella
- **Purpose:** Meta RoCE bug fixes
- **Consoles:**
  - Vulcano: `telnet 10.30.52.56 2002`
  - SuC: `telnet 10.30.52.56 2003`

### Kenya-Perf-4 (kenya-3190)
- **IP:** 10.30.52.75
- **Credentials:** root/docker
- **Card:** Saraceno (single card, 32GB memory)
- **Current User:** Sunil Akella
- **Purpose:** Meta RoCE bug fixes
- **IOMMU:** Enabled (for ATS work)
- **Consoles:**
  - Vulcano: `telnet 10.30.52.56 2009`
  - SuC: `telnet 10.30.52.56 2031`

---

## Deployment Instructions

### Step 1: Check Current Status (Before Deployment)

**Kenya-Perf-3:**
```bash
ssh root@10.30.52.66
sudo nicctl show card
sudo nicctl show version
ibv_devices
df -h /tmp
```

**Kenya-Perf-4:**
```bash
ssh root@10.30.52.75
sudo nicctl show card
sudo nicctl show version
ibv_devices
df -h /tmp
```

### Step 2: Copy Firmware to Target Hosts

**From inside Docker (tmux session `pensando-sw`):**
```bash
# Copy to kenya-perf-3
scp /sw/ainic_fw_vulcano.tar root@10.30.52.66:/tmp/

# Copy to kenya-perf-4
scp /sw/ainic_fw_vulcano.tar root@10.30.52.75:/tmp/
```

### Step 3: Deploy to Kenya-Perf-3

```bash
ssh root@10.30.52.66

# Update firmware
sudo nicctl update firmware -i /tmp/ainic_fw_vulcano.tar

# Reset card to activate new firmware
sudo nicctl reset card --all

# Wait ~10 seconds, then verify
sleep 10
sudo nicctl show card
sudo nicctl show version
ibv_devices
```

### Step 4: Deploy to Kenya-Perf-4

```bash
ssh root@10.30.52.75

# Update firmware
sudo nicctl update firmware -i /tmp/ainic_fw_vulcano.tar

# Reset card to activate new firmware
sudo nicctl reset card --all

# Wait ~10 seconds, then verify
sleep 10
sudo nicctl show card
sudo nicctl show version
ibv_devices
```

---

## Recovery Procedure (If Cards Don't Come Up)

If cards don't respond after `nicctl reset card --all`:

### Kenya-Perf-3 Recovery:
```bash
# 1. Telnet to SuC console
telnet 10.30.52.56 2003

# 2. In SuC console, run:
kernel reboot

# 3. Wait for reboot to complete (~1 minute)

# 4. Reboot the host
ssh root@10.30.52.66 'sudo reboot'

# 5. Wait 2-3 minutes, then verify
ssh root@10.30.52.66 'sudo nicctl show card'
```

### Kenya-Perf-4 Recovery:
```bash
# 1. Telnet to SuC console
telnet 10.30.52.56 2031

# 2. In SuC console, run:
kernel reboot

# 3. Wait for reboot to complete (~1 minute)

# 4. Reboot the host
ssh root@10.30.52.75 'sudo reboot'

# 5. Wait 2-3 minutes, then verify
ssh root@10.30.52.75 'sudo nicctl show card'
```

---

## Verification Checklist

### Kenya-Perf-3 (10.30.52.66)
- [ ] Card shows up: `sudo nicctl show card`
- [ ] Firmware version matches build
- [ ] RDMA device present: `ibv_devices` (should show ai0)
- [ ] No errors: `dmesg | tail -50`
- [ ] Can ping from host

### Kenya-Perf-4 (10.30.52.75)
- [ ] Card shows up: `sudo nicctl show card`
- [ ] Firmware version matches build
- [ ] RDMA device present: `ibv_devices` (should show ai0)
- [ ] No errors: `dmesg | tail -50`
- [ ] Can ping from host

---

## Quick Reference Commands

```bash
# Check build status (if needed)
tmux attach -t pensando-sw

# List firmware files in Docker
ssh into docker: cd /sw && ls -lh ainic_fw_vulcano.*

# Copy firmware to both hosts
scp /sw/ainic_fw_vulcano.tar root@10.30.52.66:/tmp/
scp /sw/ainic_fw_vulcano.tar root@10.30.52.75:/tmp/

# Deploy to kenya-perf-3
ssh root@10.30.52.66 'sudo nicctl update firmware -i /tmp/ainic_fw_vulcano.tar && sudo nicctl reset card --all'

# Deploy to kenya-perf-4
ssh root@10.30.52.75 'sudo nicctl update firmware -i /tmp/ainic_fw_vulcano.tar && sudo nicctl reset card --all'

# Verify both hosts
ssh root@10.30.52.66 'sudo nicctl show card; sudo nicctl show version; ibv_devices'
ssh root@10.30.52.75 'sudo nicctl show card; sudo nicctl show version; ibv_devices'
```

---

## Build Details

**Build Command:**
```bash
make -f Makefile.build build-rudra-vulcano-hydra-ainic-fw
```

**Build Output:**
- Firmware package: `/sw/ainic_fw_vulcano.tar` (7.5M)
- PLDM package: `/sw/ainic_fw_vulcano.pldmfw` (7.6M)
- Archive: `/sw/build-rudra-vulcano-hydra-ainic-fw.tar.gz`

**Build Time:** 2m56s (real time)

**Tmux Session:** `pensando-sw`

---

## Notes

- Both hosts are currently in use by Sunil Akella for Meta RoCE bug fixes
- Kenya-perf-4 has IOMMU enabled for ATS work
- Both hosts have single Saraceno Vulcano cards with 32GB memory
- Firmware update takes 3-5 minutes per host
- Card reset typically takes 10-15 seconds

**Last Updated:** 2026-03-03 09:00 AM
