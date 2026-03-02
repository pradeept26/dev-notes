# GT1 & GT4 Bandwidth Fix Plan

## Problem
GT1 and GT4 achieving only ~179 Gbps (half bandwidth) vs SMC1/SMC2 at 358 Gbps

## Root Cause Analysis
Both GT setups are identically configured and missing key performance parameters compared to SMC setups.

## Fix Plan

### Phase 1: Baseline Testing (10 min)
**Confirm the issue on both systems**

```bash
# On GT1
ssh root@10.30.69.101
# Run RCCL bandwidth test between GT1 and GT4
# Document current bandwidth: ~179 Gbps

# On GT4
ssh root@10.30.69.98
# Verify same issue
```

**Expected:** Both showing ~179 Gbps (half of 358 Gbps)

---

### Phase 2: Quick Test - Disable SMT (5 min)
**Test if hyperthreading is causing the issue**

```bash
# On GT1
ssh root@10.30.69.101

# Disable SMT (runtime, no reboot needed)
echo off | tee /sys/devices/system/cpu/smt/control

# Verify
lscpu | grep "Thread(s) per core"
# Should show: 1

lscpu | grep "CPU(s):"
# Should show: 192 (down from 384)

# Run RCCL test again
# Check if bandwidth improves to ~358 Gbps
```

**If bandwidth improves → SMT was the issue, make permanent in BIOS**

**If no improvement → Proceed to Phase 3**

**Restore SMT for now:**
```bash
echo on | tee /sys/devices/system/cpu/smt/control
```

---

### Phase 3: Add Missing Kernel Parameters (30 min)
**Most likely fix - add parameters matching SMC configuration**

#### Step 1: Backup Current Grub Config
```bash
# On GT1
ssh root@10.30.69.101

# Backup
cp /etc/default/grub /etc/default/grub.backup.$(date +%Y%m%d)
cp /boot/grub2/grub.cfg /boot/grub2/grub.cfg.backup.$(date +%Y%m%d)
```

#### Step 2: Edit Grub Configuration
```bash
vi /etc/default/grub

# Find line: GRUB_CMDLINE_LINUX="..."
# Add these parameters (space-separated):
#   pcie_ports=native
#   pci=bfsort
#   numa_balancing=disable
#   processor.max_cstate=0

# Example result:
# GRUB_CMDLINE_LINUX="... pci=realloc=off amd_iommu=on iommu=pt pcie_aspm=off pcie_port_pm=off pcie_ports=native pci=bfsort numa_balancing=disable processor.max_cstate=0"
```

#### Step 3: Update Grub and Reboot
```bash
# Regenerate grub config
grub2-mkconfig -o /boot/grub2/grub.cfg

# Verify the new config
grep "pcie_ports=native" /boot/grub2/grub.cfg

# Reboot
reboot
```

#### Step 4: Verify After Reboot
```bash
# Wait 2-3 min for GT1 to reboot
ssh root@10.30.69.101

# Verify new kernel parameters loaded
cat /proc/cmdline | grep pcie_ports
cat /proc/cmdline | grep pci=bfsort
cat /proc/cmdline | grep numa_balancing

# Check all NICs are up
lspci | grep Pensando | wc -l
# Should show: Many devices (8 NICs)

# Run init script if needed
/mnt/clusterfs/bringup/vulcano_hydra_rccl_bringup.sh
```

#### Step 5: Run RCCL Test
```bash
# Run bandwidth test between GT1 and GT4
# Check if bandwidth improved to ~358 Gbps

# If improved → SUCCESS!
# If not → Proceed to Phase 4
```

---

### Phase 4: BIOS Settings (If Phase 3 doesn't fix) (20 min)

#### Step 1: Access GT1 BIOS
```bash
# Reboot and enter BIOS
ssh root@10.30.69.101
reboot

# Or use BMC
# BMC IP: 10.30.69.88
# Credentials: root/0penBmc
```

#### Step 2: Check These Settings

**PCIe Configuration:**
- [ ] PCIe Speed: Gen5 (or Auto)
- [ ] PCIe Link Width: x16 (or Auto)
- [ ] Above 4G Decoding: **Enabled**
- [ ] SR-IOV Support: **Enabled**
- [ ] ARI (Alternative Routing-ID): **Enabled**
- [ ] Extended Tags: **Enabled**
- [ ] Relaxed Ordering: **Enabled**
- [ ] Max Payload Size: 256 or Auto
- [ ] Max Read Request: 512 or Auto (not 4096!)

**CPU/Performance:**
- [ ] SMT (Hyperthreading): **Disabled** (critical for RDMA!)
- [ ] C-States: **Disabled**
- [ ] Determinism Control: **Performance**
- [ ] cTDP Control: **Auto** or **Manual** (max)

**Memory:**
- [ ] NUMA: **Enabled**
- [ ] Memory Interleaving: **Disabled** (for NUMA)

**Power:**
- [ ] Power Profile: **Maximum Performance**

#### Step 3: Apply Changes and Test
```bash
# Save BIOS settings and reboot
# After boot, run RCCL test
```

---

### Phase 5: Apply to GT4 (10 min)
**Once GT1 is fixed, replicate to GT4**

```bash
# Apply same kernel parameters
ssh root@10.30.69.98

# Copy exact GRUB_CMDLINE_LINUX from GT1
vi /etc/default/grub
# Use same parameters that worked on GT1

# Update and reboot
grub2-mkconfig -o /boot/grub2/grub.cfg
reboot

# Verify and test
```

**If BIOS changes were needed:**
- Apply same BIOS settings to GT4
- Reboot and test

---

### Phase 6: Verification & Documentation (10 min)

#### Verify Both GT Systems
```bash
# GT1 bandwidth test
# Should show: ~358 Gbps ✓

# GT4 bandwidth test
# Should show: ~358 Gbps ✓

# Verify kernel parameters
ssh root@10.30.69.101 'cat /proc/cmdline'
ssh root@10.30.69.98 'cat /proc/cmdline'

# Verify SMT status
ssh root@10.30.69.101 'lscpu | grep Thread'
ssh root@10.30.69.98 'lscpu | grep Thread'
```

#### Update Documentation
```bash
# Update GT YAML files with working configuration
# Document kernel parameters
# Document BIOS settings if changed
# Add performance notes
```

---

## Quick Reference - Most Likely Fixes

### Fix 1: Kernel Parameters (Try First!)
```bash
ssh root@10.30.69.101
vi /etc/default/grub
# Add: pcie_ports=native pci=bfsort numa_balancing=disable processor.max_cstate=0
grub2-mkconfig -o /boot/grub2/grub.cfg
reboot
```

### Fix 2: Disable SMT (If Fix 1 not enough)
```bash
# Runtime test:
echo off | tee /sys/devices/system/cpu/smt/control

# Permanent: Disable in BIOS
```

### Fix 3: BIOS - Above 4G Decoding
```
Access BIOS → Advanced → PCIe → Above 4G Decoding: Enabled
```

---

## Testing After Each Fix

```bash
# Run RCCL between GT1 and GT4
# Expected: ~358 Gbps (to match SMC performance)

# Verify via console manager
cd ~/dev-notes/pensando-sw/scripts
./console-mgr.py --setup gt1 --console vulcano --all version
./console-mgr.py --setup gt4 --console vulcano --all version
```

---

## Timeline

| Phase | Duration | Reboot Needed |
|-------|----------|---------------|
| Phase 1: Baseline | 10 min | No |
| Phase 2: SMT test | 5 min | No |
| Phase 3: Kernel params | 30 min | Yes (both GT1) |
| Phase 4: BIOS (if needed) | 20 min | Yes |
| Phase 5: Apply to GT4 | 10 min | Yes |
| Phase 6: Verify & doc | 10 min | No |
| **Total** | **~1.5 hours** | 2-4 reboots |

---

## Expected Outcome

After fixes:
- ✅ GT1 <-> GT4: ~358 Gbps (matches SMC performance)
- ✅ Documented working configuration
- ✅ Both GT systems consistent

---

## Rollback Plan

If fixes cause issues:

```bash
# Restore grub config
cp /etc/default/grub.backup.<date> /etc/default/grub
grub2-mkconfig -o /boot/grub2/grub.cfg
reboot

# Restore BIOS to defaults
# Use BIOS "Load Optimized Defaults"
```

---

**Created:** 2026-02-25
**Status:** Ready to execute
**Priority:** High (50% performance loss)
**Risk:** Low (all changes are reversible)
