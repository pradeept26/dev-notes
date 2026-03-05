# Kenya-Perf Current Vulcano Firmware Status

**Date:** 2026-03-03 09:05 AM
**Checked via:** console-mgr.py

---

## Kenya-Perf-3 (kenya-1354) - Current Status

**Host:** 10.30.52.66 (root/docker)
**Console:** telnet 10.30.52.56 2003 (Vulcano on port 2002, SuC on port 2003)

**Current Firmware Version:**
```
Firmware version          : 1.125.0-pi-136
Firmware build time       : Feb 28 2026 20:20:05
Build tag                 : 1.XX.0-C-8-50694-g1c12cabfa500
Pipeline                  : rudra
P4 program                : hydra
```

**SUC Details:**
```
SUC-firmware              : mainfwa
Suc-boot                  : 0.0.1+dummy
Suc-app                   : 1.2.0+build.0.run.1822.commit.478883d8f1a9
CPLD                      : 0.2.2-saraceno-cfg0
Soc-firmware              : mainfwa
```

---

## Kenya-Perf-4 (kenya-3190) - Current Status

**Host:** 10.30.52.75 (root/docker)
**Console:** telnet 10.30.52.56 2009 (Vulcano on port 2009, SuC on port 2031)

**Current Firmware Version:**
```
Firmware version          : 1.125.0-pi-136
Firmware build time       : Feb 28 2026 20:20:05
Build tag                 : 1.XX.0-C-8-50694-g1c12cabfa500
Pipeline                  : rudra
P4 program                : hydra
```

**SUC Details:**
```
SUC-firmware              : mainfwa
Suc-boot                  : 0.0.1+dummy
Suc-app                   : 1.2.0+build.0.run.1822.commit.478883d8f1a9
CPLD                      : 0.2.2-saraceno-cfg0
Soc-firmware              : mainfwa
```

---

## Summary

**Both hosts running IDENTICAL firmware:**
- Version: `1.125.0-pi-136`
- Build date: Feb 28 2026 20:20:05
- Pipeline: rudra
- P4 program: hydra

**New firmware being deployed:**
- Branch: `hydra_125_1_a`
- Build date: Mar 3 2026 00:59:00
- Location: `/sw/ainic_fw_vulcano.tar` (7.5M)

---

## Deployment Ready

The new firmware from branch `hydra_125_1_a` is ready to be deployed to both kenya-perf-3 and kenya-perf-4.

**Console Manager Commands Used:**
```bash
# Check kenya-perf-3 version
cd ~/dev-notes/pensando-sw/scripts
./console-mgr.py --setup kenya-1354 --console vulcano --all version \
  --yaml-dir ~/dev-notes/pensando-sw/hardware/vulcano/data

# Check kenya-perf-4 version
./console-mgr.py --setup kenya-3190 --console vulcano --all version \
  --yaml-dir ~/dev-notes/pensando-sw/hardware/vulcano/data
```

**Next Steps:**
1. Copy firmware: `scp /sw/ainic_fw_vulcano.tar root@10.30.52.66:/tmp/`
2. Copy firmware: `scp /sw/ainic_fw_vulcano.tar root@10.30.52.75:/tmp/`
3. Deploy to both hosts using nicctl update firmware
4. Verify new firmware version via console-mgr.py

---

**Last Updated:** 2026-03-03 09:05 AM
