# Handoff — CT10 (Mission-P rack) AINIC setup: access, topology, issues, bring-up, recovery

**Date:** 2026-08-07
**System:** **CT10** (Comp Tray 10), **Mission-P rack** — 4× Vulcano AINIC + 4× MI GPU, connected via a **Minipack3 switch** (not back-to-back).
**Author:** Pradeep Thangaraju (prthangar), with Claude.
**Why this system:** g05-1 developed PCIe width-degradation issues (Darshan/Edmond debugging); Ganesh handed CT10 (Mission-P) for the q256 / NIC perf investigation.
**Related:** `HANDOFF_g05-1_q256_hang_and_driver_reset_saga_2026-08-06.md` (the q256 finding + g05-1 lessons). Slack: **#helios-setup-handoff** (C0BJTFPT46T), group DM **C0BN9RFQJ1M** (switch VLAN work with Arun/Ashwin/Mahesh D).

---

## TL;DR / current state
- CT10 upgraded to **FW 1.130.2-a-11 + matching host tools** (nicctl/pds/ionic), **PCIe x16 all 4**, QoS + rdma paths set, all 4 NIC links up **800G**, 4 GPUs present.
- **BLOCKED on the switch:** it's a **Minipack3 in Broadcom SDK *diag* mode with NO L2 forwarding** — so NIC→NIC traffic doesn't pass. Switch SMEs (Ashwin H / Mahesh Devadiga) are adding two VLANs via the drivshell (incremental, no cold-boot); pending the **OSFP-faceplate → logical PORT_ID** mapping.
- Switch-free fallback available: **PCS port loopback** (single-NIC RDMA test).

---

## 1. Access (important — multi-hop, isolated network)

CT10 is on the **MissionP / dpeg.amd.com network (10.223.x)** — **NOT reachable from pensando dev servers** (sw-dev9/sw-dev2). Paths:

| Hop | Target | Creds |
|-----|--------|-------|
| Host (CT10) | **10.223.206.145** | root / **Password1** |
| BMC | **10.223.207.225** | root / **0penBmc** (OpenBMC, `mfg-tool`) |
| Switch MP OS (Minipack3 COMe) | **10.223.206.110** | root / **(no password)** |
| Jump host (human) | **njcs.dpeg.amd.com** | ahds / ahds123 → then `ssh root@10.223.206.145` |
| CI box that reaches CT10 | **atlhelioscicd02.amd.com** | (reachable only from Pradeep's Windows laptop) |

### How Claude (running on sw-dev9) reaches CT10 — reverse SSH tunnel
sw-dev9 can't reach 10.223.x, so we bridge via a reverse tunnel from a box that reaches **both** (atlhelioscicd02 reaches CT10 and can SSH to sw-dev9):

1. Passwordless SSH set up: atlhelioscicd02 → `pradeept@sw-dev9.pensando.io` (ed25519 key in authorized_keys).
2. On **atlhelioscicd02** (keep running, e.g. in tmux):
   ```bash
   ssh -N -R 2210:10.223.206.145:22 pradeept@sw-dev9.pensando.io \
       -o ServerAliveInterval=30 -o ServerAliveCountMax=3
   ```
3. From **sw-dev9** (Claude side): `sw-dev9:2210` → CT10:22
   ```bash
   sshpass -p Password1 ssh -p 2210 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@localhost
   ```
- Tunnel auto-recovers when CT10 reboots (atlhelioscicd02↔sw-dev9 control conn stays up). If it dies, re-run step 2.
- **BMC/MP OS are reachable *from CT10*** (not from sw-dev9), so cold-cycle etc. go: sw-dev9 → tunnel → CT10 → `sshpass -p 0penBmc ssh root@10.223.207.225 ...`.

---

## 2. Topology & identifiers

**Switched** setup (Minipack3 = **RTSW MP3 6**), not b2b. Only **even BE NICs (0/2/4/6)** are cabled. Per-NIC subnets (CT10 = last octet 10; peers CT11=.11, CT12=.12 share the switch).

| BE NIC | OSFP faceplate port | ionic dev | netdev | Card BDF | Card UUID | GPU (`--use_rocm`) | IP |
|--------|--------------------|-----------|--------|----------|-----------|--------------------|----|
| BE 0 | **port 3** | ionic_0 | enP1p3s0f3 | 0001:01:00.0 | 42424650-5132-3632-3130-323943000000 | 0 | 1.1.1.10 |
| BE 2 | **port 11** | ionic_1 | enP2p3s0f3 | 0002:01:00.0 | 42424650-5132-3632-3130-304230000000 | 1 | 2.2.2.10 |
| BE 4 | **port 19** | ionic_2 | enP3p3s0f3 | 0003:01:00.0 | 42424650-5132-3631-3930-324538000000 | 2 | 3.3.3.10 |
| BE 6 | **port 27** | ionic_3 | enP4p3s0f3 | 0004:01:00.0 | 42424650-5132-3631-3930-314532000000 | 3 | 4.4.4.10 |

- NIC function BDF = `000X:03:00.3`; GPU = `000X:04:00.0` (same PCIe segment → GDR-paired).
- Kernel: **6.16.1-0_fbk2_brcmrdma5_35** (custom FB kernel — matters for DKMS).
- ionic device names reshuffle after `nicctl reset`; a clean `modprobe` restores canonical order. Re-map with:
  `for d in /sys/class/infiniband/ionic_*; do echo "$(basename $d) -> $(basename $(readlink -f $d/device)) -> $(ls $d/device/net)"; done`

### Key paths (on CT10)
- IP bring-up script: `/root/set_nmcli_ip.sh` → run `SRV_NUM=10 ./set_nmcli_ip.sh` (assigns enP1→1.1.1.10, enP2→2.2.2.10, enP3→3.3.3.10, enP4→4.4.4.10, MTU 9000)
- FW/host bundle: `/root/ainic/ainic_bundle_1.130.2-a-11/` (`firmware/ainic_fw_vulcano.tar`, `host_sw_pkg/install.sh`)
- perftest (bundle): `perftest-25.07.*` (system). For **GDR** (`--use_rocm`) build a ROCm-enabled perftest from `host_sw_pkg/ionic_driver/src/drivers-linux.tar.xz` (as on g05-1) if the system one lacks `--use_rocm`.

---

## 3. Issues we're tracking

1. **★ q256 QP-setup hang (primary):** on g05-1 (FW 1.130.2-a-12), 256-QP `ib_write_bw` hangs during **client-side QP setup** — reproducible in isolation, all sizes, both dirs, host-mem too, **no CQ/RTR error**; q16/q1024/q2048 fine, only ~256. Goal on CT10: reproduce on the official 1.130.2-a-11 build. (See the g05-1 handoff for the full characterization + reproducer.)
2. **★ Switch has no L2 forwarding (current blocker):** RTSW MP3 6 = Minipack3 (BCM78900/TH5) in **Broadcom SDK diag mode** (`bcm.user`); active config `Minipack3_RSW_FE_config_AEC_LtOff_2x400_Port65LTOff.yml` is **PHY/serdes bring-up only** — no VLAN/L2/L3. Ports link up (800G) but the ASIC doesn't forward → NIC→NIC = 100% loss, no gateway on any subnet. Fix in progress: SMEs add two VLANs via drivshell (see §6).
3. **PCIe width degradation on reset (AI-7437 pattern):** `nicctl reset card`, firmware `--reset`, and warm reboots can re-train PCIe to **x1/x2/x8**. Only a **BMC AC cold-cycle** recovers x16. (Seen on CT10 flash: 0002/0004 dropped off, 0003→x8; cold-cycle fixed all to x16.)
4. **pds-dkms fragility on this kernel:** the pre-installed a-55 pds-dkms had **0-byte source files** (Makefile/Kbuild/dkms.conf) → `nicctl` "no AMD NIC cards detected". Fixed by restoring source from the RPM + `dkms build/install`. The a-11 bundle installed pds cleanly.
5. **Driver install needs quiescing:** `install.sh -y` fails ("rmmod ib_peer_mem in use" / pds extract) if modules are loaded. **Quiesce first:** `rmmod amdgpu; modprobe -r ionic_rdma ib_peer_mem ionic`, then run `install.sh -y`.
6. **amdgpu load risk:** on g05-1 a `modprobe amdgpu` once crash-rebooted the host — load it **alone** and confirm the host stays up before proceeding. amdgpu is blacklisted at boot (`modprobe amdgpu` after each boot for GDR).

---

## 4. Bring-up (from a clean/rebooted state)
```bash
# 0. reach CT10 via the tunnel (see §1)
# 1. drivers (should auto-load; else:)
sudo modprobe pds_core pds_fwctl ionic ionic_rdma
lsmod | grep -E "^ionic|^pds"        # expect pds_core, pds_fwctl, ionic, ionic_rdma
sudo nicctl show card                 # expect 4 cards (needs pds; if "no cards" -> §5.2)
# 2. interfaces + IPs
cd /root && SRV_NUM=10 ./set_nmcli_ip.sh
# 3. QoS + rdma paths (per card 0001..0004)
for c in 0001:01:00.0 0002:01:00.0 0003:01:00.0 0004:01:00.0; do
  sudo nicctl update qos --classification-type dscp -b $c
  sudo nicctl update qos dscp-to-purpose  --dscp 48 --purpose rdma-ack -b $c
  sudo nicctl update qos dscp-to-priority --dscp 48 --priority 2 -b $c
  sudo nicctl update qos dscp-to-priority --dscp 32 --priority 3 -b $c
  sudo nicctl update pipeline rdma path -p 0 --count 8 -b $c   # path --count 1-80 valid on a-11
done
# 4. GPUs (only if GDR) — load carefully, verify host stays up
sudo modprobe amdgpu; sleep 5; ls -d /sys/class/drm/card[0-9] | wc -l
# 5. hugepages (host-mem tests): sudo sysctl -w vm.nr_hugepages=4096
```
**Sanity:** ports `nicctl show port` = 800G UP; IB devices `ionic_0..3` state `4: ACTIVE`. (Actual NIC→NIC traffic needs the switch VLANs — §6.)

---

## 5. Recovery

### 5.1 Card dropped off PCIe / PCIe width x1/x2/x8 (after flash/reset)
BMC AC cold-cycle (recovers all cards + re-trains x16). From CT10:
```bash
sshpass -p 0penBmc ssh -o StrictHostKeyChecking=no root@10.223.207.225 \
    "mfg-tool power-control -p 0 -a cycle -s standby"
```
Node returns in ~10–13 min (GPU-node cold boot). Then re-verify:
```bash
for b in 0001 0002 0003 0004; do echo "$b: w=$(cat /sys/bus/pci/devices/$b:03:00.3/current_link_width)"; done   # want 16
```
`/root` and `/tmp` are disk-backed (survive reboot); netns/QoS/fclk/amdgpu do NOT — re-run §4.

### 5.2 `nicctl show card` = "no AMD NIC cards detected" (pds not loaded/built)
```bash
dkms status | grep -i pds                      # if missing/broken:
# restore pds source from the RPM then rebuild:
cd /tmp && rm -rf pdsrpm && mkdir pdsrpm && cd pdsrpm
rpm2cpio /opt/amd/ainic/repo/pds-dkms-*.rpm | cpio -idm
sudo cp -rf usr/src/pds-*/. /usr/src/pds-<ver>/         # overwrite 0-byte source
sudo dkms remove pds/<ver> --all; sudo dkms build pds/<ver>; sudo dkms install pds/<ver> --force
sudo modprobe pds_core pds_fwctl; sudo nicctl show card
```

### 5.3 Driver stack broken / after driver churn → clean reinstall
```bash
sudo rmmod amdgpu; sudo modprobe -r ionic_rdma ib_peer_mem ionic     # quiesce first
cd /root/ainic/ainic_bundle_1.130.2-a-11/host_sw_pkg && sudo bash install.sh -y
# ("Update initramfs failed" at the end is cosmetic; verify dkms status + nicctl show card)
```

### 5.4 Error-recovery after killing perftest with active QPs
`sudo nicctl clear rdma internal queue` (or reload ionic_rdma). Scoped-kill perftest with `pkill -9 -f "[i]b_write_bw.*ionic_N"` (the `[i]` avoids self-matching the SSH command; plain `pkill -f "ib_write_bw.*ionic_N"` kills your own session).

---

## 6. Switch (Minipack3 / RTSW MP3 6) — state & the change we need

- Platform: **Minipack3 (Montblanc), Broadcom BCM78900 (TH5), SDK 6.5.32**, diag mode via `/usr/local/cls_diag/SDK/bcm.user -y <config>.yml`. **Not FBOSS/SONiC.**
- Active config = **PHY/port bring-up only** (`PC_PORT`, `PC_PM_CORE`, lane maps, 2×400G, AEC, LT-off). **No L2/VLAN/L3.**
- `bcm.user` **cold-boots** the whole ASIC on launch (no warmboot) → a config *reload* flaps ALL trays (CT11/CT12). BUT a **live `drivshell`** is attached to the running ASIC, so **classic `vlan` CLI can be run incrementally (no cold-boot)** — confirmed (CT10 links stayed up while SME queried it).
- **The change (owned by switch SMEs Ashwin H / Mahesh Devadiga):** two isolated VLANs so each CT10 pair loops NIC→NIC through the switch:
  - VLAN 30: OSFP **port 3 ↔ 11** (NIC0↔NIC2)
  - VLAN 40: OSFP **port 19 ↔ 27** (NIC4↔NIC6)
  - drivshell: `vlan create <id> PortBitMap=<pbmp> UntagBitMap=<pbmp>` **+ set PVID + remove ports from VLAN 1** (else they share VLAN-1 flood domain with CT11/CT12 → cross-talk/breaks isolation).
- **Blocker:** need **OSFP faceplate 3/11/19/27 → logical PORT_ID** mapping (PortBitMap uses logical ports). Neither we nor the SMEs had it; resolve via drivshell `ps` (link-up OSFPs = our NICs) + the wiring/topology (posted in group DM C0BN9RFQJ1M).
- Config's enabled **800G logical PORT_IDs** (for reference): `1,22,44,66,88,110,132,154,176,198,220,242,264,286,308,330`.

### Switch-free alternative (no switch change, no peer) — PCS loopback
Reproduces the RDMA datapath + q256 on a single NIC:
```bash
sudo nicctl update port -p <port_uuid> --loopback-mode pcs   # TX->RX inside NIC (full pipeline)
# create macvlan in TWO separate netns on the same NIC (separate netns mandatory -> ud_loopback=0)
# run ib_write_bw server(ns2)/client(ns1) on the same ionic dev, --use_rocm on both
# verify ud_loopback=0; cleanup: --loopback-mode none
```
(See the `/analyze-latency` skill for the full macvlan+loopback recipe.)

---

## 7. FW upgrade reference (how CT10 got to 1.130.2-a-11)
- **Official builds:** `repo.radeon.com/amdainic/pensando/el9/<ver>/` (latest 1.130.2-a = **-a-11**; has host RPMs + `amdainic-rudra-vulcano-hydra-firmware` RPM). **FW bundle:** hourly server `http://192.168.64.149/builds/hourly/<ver>/rudra-bundle/release-artifacts/hydra/vulcano/ainic_bundle_<ver>.tar.gz` (reachable from sw-dev9, not CT10).
- Procedure: download bundle on sw-dev9 → `scp -P 2210` to CT10:/root/ainic → extract → `nicctl update firmware -i firmware/ainic_fw_vulcano.tar --all --reset` (detached; **no `--force`**) → **BMC AC cold-cycle** to recover PCIe x16 → `install.sh -y` for host tools (quiesce first) → re-run bring-up (§4).
- Branch note: FW **and** host tools must match branch (1.130.0 → 1.130.2 is a branch change), so upgrade both.

---

## 8. Open items / next steps
1. **Switch VLANs** (Ashwin/Mahesh D) — map OSFP 3/11/19/27 → logical ports, `vlan create` the 2 pairs + PVID/VLAN-1 isolation. Then run q16 → q256.
2. **q256 reproduction** on 1.130.2-a-11 (official) once forwarding is on — compare to g05-1's a-12 finding.
3. If switch stalls, run the **PCS-loopback** q256 as a parallel track (no switch dependency).
4. Node is **shared** (CT11/CT12 on the same Minipack3) — keep any switch change scoped to CT10's ports; never cold-boot/reload the switch config without coordinating.
