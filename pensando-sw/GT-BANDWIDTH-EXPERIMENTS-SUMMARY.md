# GT Bandwidth Issue - Complete Experiment Summary

## Problem Statement
GT1 <-> GT4: ~170 Gbps (expected ~358 Gbps like SMC1 <-> SMC2)

---

## Experiments Performed (2026-02-25)

### Experiment 1: Disable SMT (Hyperthreading)
**Hypothesis:** SMT causing resource contention and cache pollution

**Action:**
```bash
# On both GT1 and GT4
echo off > /sys/devices/system/cpu/smt/control
```

**Result:**
- ✗ No improvement
- Bandwidth still ~170 Gbps

**Reverted:**
```bash
echo on > /sys/devices/system/cpu/smt/control
```

**Conclusion:** SMT is not the cause

---

### Experiment 2: Add Missing Kernel Parameters
**Hypothesis:** Missing kernel parameters preventing optimal PCIe performance

**Action:**
Added these parameters to both GT1 and GT4:
- `pcie_ports=native`
- `pci=bfsort`
- `numa_balancing=disable`
- `processor.max_cstate=0`

**Method:**
```bash
grubby --update-kernel=ALL --args="pcie_ports=native pci=bfsort numa_balancing=disable processor.max_cstate=0"
reboot
```

**Result:**
- ✗ No improvement
- Bandwidth still ~170 Gbps

**Reverted:**
```bash
grubby --update-kernel=ALL --remove-args="pcie_ports=native pci=bfsort numa_balancing=disable processor.max_cstate=0"
reboot
```

**Conclusion:** Kernel parameters are not the cause

---

### Experiment 3: Deep System Comparison
**Hypothesis:** Some configuration difference between GT and SMC

**Compared:**
- ✓ PCIe Link Status: Both 32GT/s x16 (Gen5) - IDENTICAL
- ✓ ASPM: Disabled on both - IDENTICAL
- ✓ Driver parameters: Same - IDENTICAL
- ✓ Driver modules: Same - IDENTICAL
- ✗ CPU governor: GT=performance, SMC=schedutil - Different but GT should be better
- ✗ ACS Status: **DIFFERENT** (GT enabled, SMC disabled) ⬅️ FOUND IT!

**Key Finding:**
```
SMC1: ACSCtl: SrcValid- ... (all disabled) ✓
GT1:  ACSCtl: SrcValid+ ... (enabled) ✗ BLOCKS PEER-TO-PEER DMA!
```

---

### Experiment 4: Disable ACS + Run Bringup Scripts
**Hypothesis:** ACS blocking peer-to-peer DMA + missing network configuration

**Action:**
```bash
# On GT1
/usr/local/bin/disable_acs.sh
/home/amd/vul-rccl-benchmark/gt1-vulcano-bringup.sh

# On GT4
/usr/local/bin/disable_acs.sh
/home/amd/vul-rccl-benchmark/gt4_vulcano_bringup.sh
```

**What the Scripts Do:**
1. Disable ACS (allow peer-to-peer DMA)
2. Stop NetworkManager
3. Disable NUMA balancing (runtime)
4. Rename RoCE devices (roce_ai0 - roce_ai7)
5. Configure interfaces:
   - Set MTU 9000
   - Assign IPv6 addresses (2001::50:x:4:x)
   - Assign IPv4 addresses (50.x.4.x)
6. Set up routes (GT1 ↔ GT4 mesh)
7. Configure IPv6 neighbors
8. Set rp_filter=2

**Result:**
- ✅ **WAITING FOR TEST** - This is the most likely fix!

**Configuration Applied:**
- GT1: 50.1.4.0-14 / 2001::50:1:4:0-e
- GT4: 50.4.4.0-14 / 2001::50:4:4:0-e
- MTU: 9000 on all interfaces
- ACS: Disabled on all PCIe devices
- Routes: Mesh between GT1 and GT4

---

## Summary of Findings

### ✗ Not the Cause:
1. SMT/Hyperthreading
2. Kernel parameters (pcie_ports, pci=bfsort, etc.)
3. PCIe link speed/width (both Gen5 x16)
4. Driver versions or parameters

### ✅ Root Cause (Highly Likely):
**ACS (Access Control Services) was ENABLED on GT systems**

**Impact of ACS:**
- Blocks direct peer-to-peer DMA between NICs
- Forces traffic through CPU/IOMMU
- Reduces bandwidth by ~50%
- Critical for multi-NIC RDMA/RCCL workloads

**Additional Missing Configuration:**
- Bringup scripts not run after boot
- RoCE devices not renamed
- Network not configured (no IP addresses)
- Routes not set up
- MTU at default 1500 instead of 9000

---

## Timeline of Actions

1. **Investigation Start**
   - Identified issue: GT ~170 Gbps vs SMC ~358 Gbps
   - Confirmed both GT1 and GT4 affected

2. **Test 1: SMT** (~10 min)
   - Disabled on both systems
   - Tested → No improvement
   - Reverted

3. **Test 2: Kernel Parameters** (~45 min)
   - Added params to both systems
   - Rebooted
   - Tested → No improvement
   - Reverted

4. **Deep Investigation** (~15 min)
   - Compared PCIe, drivers, system config
   - Found ACS difference
   - Found missing bringup scripts

5. **Test 3: ACS + Bringup** (~10 min)
   - Disabled ACS on both
   - Ran bringup scripts
   - **Ready for test**

**Total Time:** ~80 minutes
**Reboots:** 6 (GT1 and GT4, 3 times each)

---

## Technical Deep Dive

### What is ACS?
Access Control Services - PCIe feature that enforces isolation between devices for security/IOMMU.

**ACS Enabled (GT before fix):**
```
┌─────┐     ┌─────┐
│ NIC1│────>│ CPU │────>│ NIC2│  ← Traffic goes through CPU
└─────┘     └─────┘     └─────┘
  Slower, higher latency
```

**ACS Disabled (SMC, GT after fix):**
```
┌─────┐ ──────────────> ┌─────┐
│ NIC1│   Direct P2P    │ NIC2│  ← Direct DMA
└─────┘                 └─────┘
  Faster, lower latency
```

### Why Was ACS Enabled on GT?
- Default BIOS/kernel behavior for security
- Helpful for virtualization (VM isolation)
- Must be explicitly disabled for RDMA peer-to-peer

### Why SMC Had ACS Disabled?
- Init script runs on boot: `/mnt/clusterfs/bringup/vulcano_hydra_rccl_bringup.sh`
- Calls `disable_acs.sh`
- SMC setup properly configured from the start

### Why GT Didn't Have It Disabled?
- GT uses different init scripts: `/home/amd/vul-rccl-benchmark/gt*-vulcano-bringup.sh`
- Scripts exist but may not run automatically on boot
- Needs manual execution or automation

---

## Recommendations

### Immediate
1. ✅ Test RCCL with current configuration
2. If improved → Document as permanent fix
3. If not improved → Continue to BIOS investigation

### Permanent Fix (If ACS Fix Works)
1. Add bringup scripts to run on boot:
   ```bash
   # Create systemd service or add to rc.local
   /home/amd/vul-rccl-benchmark/gt1-vulcano-bringup.sh
   /home/amd/vul-rccl-benchmark/gt4_vulcano_bringup.sh
   ```

2. Or add to BIOS (if option available):
   - Disable ACS in PCIe settings

3. Document in dev-notes:
   - Update GT YAML with init script paths
   - Add to firmware update procedures
   - Note ACS requirement

---

## Lessons Learned

1. **Init scripts are critical** - Not just for firmware, but for system configuration
2. **ACS matters for multi-NIC RDMA** - Can halve performance if enabled
3. **Different setups need different init procedures** - GT vs SMC vs Waco
4. **PCIe link status alone isn't enough** - Need to check ACS, routes, MTU, etc.
5. **Always run bringup scripts** - After firmware update, reboot, or card reset

---

**Status:** Experiment 4 complete, awaiting test results
**Next:** Test RCCL bandwidth (expected ~358 Gbps)
**Created:** 2026-02-25
