# GT Performance Issue - Half Bandwidth Debug

## Problem Statement

**Observed:**
- SMC1 <-> SMC2: 358 Gbps (RCCL) ✓
- GT1 <-> GT4: ~179 Gbps (RCCL) ✗ (Half bandwidth!)

**Expectation:** GT should also achieve ~358 Gbps

## Diagnostic Results

### ✅ PCIe Link - IDENTICAL (Not the issue)
```
SMC1: 32GT/s x16 (Gen5, full width)
GT1:  32GT/s x16 (Gen5, full width)
```

### ✅ ASPM - IDENTICAL
```
Both: pcie_aspm=off (disabled)
```

### ⚠️ Kernel Parameters - DIFFERENCES FOUND

**SMC1 (Ubuntu 5.15.0):**
```
pci=realloc=off
iommu=pt
intel_iommu=on
amd_iommu=on
pcie_ports=native
pcie_aspm=off
pci=bfsort
processor.max_cstate=0
intel_idle.max_cstate=0
intel_pstate=disable
numa_balancing=disable
```

**GT1 (RHEL 6.9.0):**
```
pci=realloc=off
iommu=pt
amd_iommu=on
pcie_aspm=off
pcie_port_pm=off  ⬅️ EXTRA
selinux=0
```

**Key Differences:**
1. GT1 missing: `pcie_ports=native`
2. GT1 missing: `pci=bfsort`
3. GT1 has: `pcie_port_pm=off` (SMC doesn't have this)
4. GT1 missing: C-state and P-state disabling
5. GT1 missing: `numa_balancing=disable`
6. GT1 missing: `intel_iommu=on` (GT has AMD CPU, but worth noting)

### System Differences

**SMC1:**
- CPU: AMD EPYC 9554 (64-core)
- OS: Ubuntu 5.15.0
- CPUs: 128 (SMT disabled: 1 thread/core)

**GT1:**
- CPU: AMD EPYC 9654 (96-core)
- OS: RHEL 6.9.0
- CPUs: 384 (SMT enabled: 2 threads/core)
- Additional: 8x MI300X GPUs present

## Likely Root Causes

### 1. Missing `pcie_ports=native` (HIGH PROBABILITY)
This controls PCIe port driver behavior. Missing it can impact performance.

### 2. SMT Enabled on GT (MEDIUM PROBABILITY)
GT1 has hyperthreading enabled (384 CPUs vs 192 cores).
Can cause scheduling issues affecting RDMA/RCCL performance.

### 3. NUMA Balancing (LOW-MEDIUM)
SMC explicitly disables it, GT doesn't.

### 4. GPU Interference (MEDIUM)
GT1 has 8x MI300X GPUs competing for PCIe bandwidth.

## Recommended Actions

### Test 1: Add Missing Kernel Parameters to GT

```bash
ssh root@10.30.69.101

# Edit grub config
vi /etc/default/grub

# Add to GRUB_CMDLINE_LINUX:
pcie_ports=native pci=bfsort numa_balancing=disable processor.max_cstate=0

# Update grub
grub2-mkconfig -o /boot/grub2/grub.cfg

# Reboot
reboot

# After reboot, test RCCL again
```

### Test 2: Disable SMT on GT

```bash
ssh root@10.30.69.101

# Disable hyperthreading
echo off | sudo tee /sys/devices/system/cpu/smt/control

# Verify
lscpu | grep "Thread(s) per core"
# Should show: 1

# Test RCCL
# If improved, make permanent in BIOS
```

### Test 3: Check RCCL is Using Correct NICs

```bash
# Verify RCCL is actually using all 8 NICs
# Check RCCL_SOCKET_IFNAME or similar env vars

# On GT1
ibv_devices
# Should show ai0-ai7

# Check which devices RCCL is using during test
```

### Test 4: Check for PCIe Errors

```bash
# On GT1
lspci -vvv -d :1003 | grep -A 5 "CorrectableError\|UncorrectableError"

# Check dmesg for PCIe errors
dmesg | grep -i "pcie.*error\|aer"
```

### Test 5: BIOS Settings to Verify

Access GT BIOS and check:

**PCIe Configuration:**
- [ ] PCIe Speed: Gen5 or Auto
- [ ] PCIe Link Width: x16
- [ ] Bifurcation: Correct for your setup
- [ ] Above 4G Decoding: Enabled
- [ ] SR-IOV: Enabled
- [ ] ARI: Enabled
- [ ] Extended Tags: Enabled
- [ ] Relaxed Ordering: Enabled
- [ ] No Snoop: Enabled

**CPU/Performance:**
- [ ] SMT/Hyperthreading: Try disabling
- [ ] C-States: Disabled
- [ ] P-States: Disabled
- [ ] Determinism Control: Performance

**Memory:**
- [ ] NUMA: Enabled
- [ ] Memory Interleaving: Disabled

**Power:**
- [ ] Power Profile: Maximum Performance

## Investigation Script

Run this comprehensive check:

```bash
#!/bin/bash
# Run on both SMC1 and GT1

echo "=== System Info ==="
uname -a
lscpu | grep -E "Model|CPU\(s\)|Thread|Core|NUMA"

echo ""
echo "=== Kernel Parameters ==="
cat /proc/cmdline

echo ""
echo "=== PCIe Link Status ==="
lspci -d :1003 -vvv | grep -E "LnkSta|LnkCap" | head -16

echo ""
echo "=== PCIe Device Control ==="
lspci -d :1003 -vvv | grep -E "DevCtl.*MaxRead|DevCtl.*MaxPayload" | head -8

echo ""
echo "=== IOMMU Status ==="
dmesg | grep -i iommu | grep -i enabled

echo ""
echo "=== RDMA Devices ==="
ibv_devices

echo ""
echo "=== Network Interfaces ==="
ip link show | grep -E "^[0-9]|benic"

echo ""
echo "=== Driver Info ==="
modinfo ionic_rdma | grep -E "version|parm"

echo ""
echo "=== NUMA Topology ==="
numactl --hardware | head -20
```

## Quick Bandwidth Test

```bash
# Single NIC test
ib_write_bw -d ai0 --report_gbits

# All NICs aggregate
# Run RCCL test and check per-NIC bandwidth
```

## Expected Fix

Most likely one of:
1. Add `pcie_ports=native pci=bfsort` to GT kernel cmdline
2. Disable SMT/hyperthreading on GT
3. BIOS PCIe setting (Above 4G, bifurcation, etc.)
4. RCCL not using all 8 NICs properly

---
**Status:** Investigation needed
**Priority:** High (50% performance loss)
**Created:** 2026-02-25
