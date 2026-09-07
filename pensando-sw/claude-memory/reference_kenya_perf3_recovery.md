---
name: kenya-perf-3/perf-4 out-of-band recovery (BMC/PDU/console)
description: BMC/APC/console access + power-cycle recovery for kenya-perf-3 (perf-3) when host wedges; hugepages lost on reboot
type: reference
originSessionId: 1418ad7a-e393-49d8-aa61-76d2bde9f02b
---
Recovery access for **kenya-perf-3 / perf-3** (10.30.52.66, sender) — from ~/dev-notes/pensando-sw/hardware/vulcano/data/kenya-1354.yml (perf-4 = kenya-3190.yml):
- **BMC:** 10.30.52.61, admin / `Pen1nfra$` — **ipmitool needs `-I lanplus -C 17`** (cipher 3/1 fail "invalid authentication algorithm"). `-H 10.30.52.61 -U admin -P 'Pen1nfra$'`.
- **APC PDU:** 10.30.52.57 port 19, apc/apc.
- **NIC console (Saraceno):** Vulcano `telnet 10.30.52.56 2002`, SuC `telnet 10.30.52.56 2003`. (This is the NIC/DSC console, NOT the x86 host OS console.)
- Host SSH root/docker. Switch = Micas 10.30.52.100 port 1/16 admin/Micas123.

**When host wedges (pingable but SSH+SOL login hang — hard memory pressure):**
1. In-band SSH + BMC SOL login both hang (getty/PAM can't fork) → must power-cycle.
2. **Warm `chassis power cycle` did NOT clear a stuck POST** — needed a **clean off/on**: `chassis power off` → wait 20s → `chassis power on`. (Matches dev-notes flag: Kenya perf nodes have unreliable PCIe link-training after reboot/BMC-reset; full power drain helps.)
3. Cold boot ~7 min to ping (512GB memory training, silent console). NIC PCIe re-enumerated clean (c1:00.0).
4. Re-bringup: `cd /root/gaurav && bash m4setup.sh` → 4 planes UP + IPs, RDMA PORT_ACTIVE, cross-plane ping OK.
5. **Hugepages are LOST on reboot** — must reconfigure: `echo 3 > /proc/sys/vm/drop_caches; echo 4096 > /proc/sys/vm/nr_hugepages; mount -t hugetlbfs nodev /dev/hugepages` (P3 uses 4096 = 8GB). Without this, `ib_write_bw --use_hugepages` fails "Failed to allocate hugepages".
6. Sanity: 8-QP bidir 4-plane ~1353 Gbps = healthy.
