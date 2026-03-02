#!/bin/bash
#
# PCIe Bandwidth Debug Script
# Compares PCIe configuration between working (SMC) and slow (GT) setups
#

cat << 'EOF'
╔═══════════════════════════════════════════════════════════════════════╗
║           PCIe Bandwidth Debugging Guide                             ║
╚═══════════════════════════════════════════════════════════════════════╝

PROBLEM:
--------
- SMC1 <-> SMC2: 358 Gbps (Full bandwidth) ✓
- GT1 <-> GT4:   ~179 Gbps (Half bandwidth) ✗

INITIAL FINDINGS:
-----------------
✓ PCIe Link: Both 32GT/s x16 (Gen5) - SAME
✓ ASPM: Disabled on both - SAME
? MaxReadReq: Need to verify actual values
? Other PCIe settings: TBD

═══════════════════════════════════════════════════════════════════════

DIAGNOSTIC COMMANDS TO RUN:
===========================

1. Compare Full PCIe Configuration
-----------------------------------

On SMC1:
ssh ubuntu@10.30.75.198
sudo lspci -d :1003 -vvv > /tmp/smc1-pcie.txt
# 1003 = Pensando Ethernet Controller device ID

On GT1:
ssh root@10.30.69.101
lspci -d :1003 -vvv > /tmp/gt1-pcie.txt

Compare:
diff /tmp/smc1-pcie.txt /tmp/gt1-pcie.txt

Look for differences in:
- MaxReadReq
- MaxPayload
- RelaxedOrdering
- NoSnoop
- Extended tags
- Phantom functions

2. Check PCIe Root Complex Settings
------------------------------------

On both systems:
lspci -tv | grep -A 10 Pensando

Look for:
- Bifurcation settings
- PCIe slot configuration
- NUMA node assignment

3. Check ACS (Access Control Services)
---------------------------------------

On both systems:
lspci -vvv | grep -i ACS

ACS can impact peer-to-peer DMA performance

4. Check IOMMU Configuration
-----------------------------

On both systems:
cat /proc/cmdline | grep iommu
dmesg | grep -i iommu

Compare:
- SMC1: iommu=pt (passthrough)
- GT1: amd_iommu=on iommu=pt

5. Check for PCIe Errors
------------------------

On both systems:
lspci -vvv -d :1003 | grep -i "CorrErr\|UncorrErr\|Fatal"

6. Check CPU/Memory Bandwidth
------------------------------

On both systems:
numactl --hardware
lscpu | grep NUMA

Check if:
- NICs on same NUMA node
- Memory bandwidth available
- CPU affinity set correctly

7. Check Driver/Module Parameters
----------------------------------

On both systems:
modinfo ionic_rdma
modinfo ionic
cat /sys/module/ionic_rdma/parameters/*

8. Check RCCL Configuration
----------------------------

Compare RCCL environment variables and settings between setups

9. Network Topology Check
--------------------------

GT1/GT4 use different topology (800G Leaf-Spine vs Micas switch)
Check if switch configuration impacts bandwidth

═══════════════════════════════════════════════════════════════════════

BIOS SETTINGS TO CHECK:
=======================

Access BIOS on GT systems and compare with SMC:

1. PCIe Settings:
   - PCIe Speed: Gen5/Auto
   - PCIe Link Width: x16/Auto
   - Above 4G Decoding: Enabled
   - MMIO High Base/Size: Check values
   - SR-IOV Support: Enabled
   - ARI Support: Enabled

2. CPU/Memory Settings:
   - NUMA: Enabled
   - Memory Interleaving: Disabled (for NUMA)
   - Determinism Slider: Performance
   - cTDP: Check setting

3. Power Management:
   - C-States: Disabled or minimal
   - P-States: Disabled
   - Turbo: Enabled

4. Advanced:
   - IOMMU: Enabled
   - ACS: Check setting
   - Relaxed Ordering: Enabled
   - Extended Tags: Enabled

═══════════════════════════════════════════════════════════════════════

RECOMMENDED DEBUG SEQUENCE:
===========================

Phase 1: Quick Checks (5 min)
------------------------------
1. PCIe link status (already done - both x16 Gen5) ✓
2. Check for PCIe errors
3. Compare kernel command line
4. Check MaxReadReq actual values

Phase 2: Detailed PCIe Comparison (15 min)
-------------------------------------------
1. Full lspci -vvv comparison
2. Check all PCIe capability differences
3. Root complex configuration
4. Slot assignment

Phase 3: BIOS Investigation (30 min)
-------------------------------------
1. Access GT BIOS
2. Compare with SMC BIOS
3. Look for PCIe/performance differences
4. Document and test changes

Phase 4: Driver/Software (15 min)
----------------------------------
1. Compare driver parameters
2. Check RCCL settings
3. Verify NUMA configuration
4. Check CPU affinity

═══════════════════════════════════════════════════════════════════════

SPECIFIC COMMANDS TO RUN NOW:
==============================

# Get full diagnostics from both
ssh ubuntu@10.30.75.198 << 'ENDSSH'
echo "=== SMC1 Diagnostics ==="
echo "PCIe Devices:"
lspci -d :1003
echo ""
echo "PCIe Details (first device):"
sudo lspci -d :1003 -vvv -s 08:00.0 | grep -E "(DevCtl|LnkSta|MaxRead|MaxPayload)"
echo ""
echo "Kernel cmdline:"
cat /proc/cmdline
echo ""
echo "IOMMU groups:"
find /sys/kernel/iommu_groups/ -type l | wc -l
ENDSSH

ssh root@10.30.69.101 << 'ENDSSH'
echo "=== GT1 Diagnostics ==="
echo "PCIe Devices:"
lspci -d :1003
echo ""
echo "PCIe Details (first device):"
lspci -d :1003 -vvv -s 08:00.0 | grep -E "(DevCtl|LnkSta|MaxRead|MaxPayload)"
echo ""
echo "Kernel cmdline:"
cat /proc/cmdline
echo ""
echo "IOMMU groups:"
find /sys/kernel/iommu_groups/ -type l | wc -l
ENDSSH

EOF
