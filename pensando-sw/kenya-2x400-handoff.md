# Kenya perf-3/perf-4 Testbed — Handoff (current profile: 2×400G)

Self-contained runbook for running experiments on the kenya perf-3 ↔ perf-4 Vulcano AI-NIC
testbed. Current state: **firmware 1.130.0-a-106-82 (pic_rl/RL build), profile
`meta-roce-2x400G-4` (2 ports), 2 planes up, RDMA active.** You can run IB immediately
(see §5–6); reflash/bringup only if you reboot or change profile.

> ⚠️ **Coordinate before using** — this setup is shared. Confirm it's free first.

---

## 1. Access

| Node | Role | Mgmt IP | SSH | Planes (2×400G) |
|------|------|---------|-----|-----------------|
| perf-3 (kenya-1354, SN FPF26040014) | **client/sender** | 10.30.52.66 | `root` / `docker` | 19.1.0.2, 19.2.0.2 (base 19.0.0.2) |
| perf-4 (kenya-3190, SN FPF26040001) | **server/receiver** | 10.30.52.75 | `root` / `docker` | 19.1.0.1, 19.2.0.1 (base 19.0.0.1) |

```bash
# SSH helper (from a host that can reach the mgmt net)
SSH="sshpass -p docker ssh -o StrictHostKeyChecking=no"
$SSH root@10.30.52.66 "hostname"
```

- **BDF** `0000:c1:00.0` · **ASIC** vulcano · **RDMA dev** `rocep195s0f3` · **base netdev** `enp195s0f3`
- **BMC (perf-3):** 10.30.52.61 — `admin` / `Pen1nfra$` — **ipmitool needs `-I lanplus -C 17`** (other cipher suites fail). APC PDU 10.30.52.57 port 19 (apc/apc). Console (NIC): `telnet 10.30.52.56 2002`.
- perf-4 BMC 10.30.52.74 has been unreliable/unreachable — use in-band or perf-3 BMC.

---

## 2. Current firmware (save-to-flash)

- **Running:** `SOC-OS-A : 1.130.0-a-106-82-ge922abb67e8` (custom build with the **pic_rl** rate-limiter feature), partition A. Host `nicctl --version` matches.
- **Flash image on host (perf-3 & perf-4):** `/root/gaurav/ainic_fw_vulcano.pic_rl.tar` (the RL/pic_rl firmware). Other images in `/root/*/ainic_fw_vulcano*.tar` and bundles in `/root/*/ainic_bundle_*`.
- **RL-capable host binary:** `/root/pradeept/nicctl_tot.bin` (needed for the `debug ... rate-limit` commands; stock `nicctl` lacks them).

**Flash the same image (only if you need to re-flash):**
```bash
BDF=0000:c1:00.0
# on the target node:
nicctl update firmware -i /root/gaurav/ainic_fw_vulcano.pic_rl.tar --all --reset --bdf $BDF
# --all + --reset = program both main partitions and reset the card. Wait ~90s, then verify.
nicctl show version firmware --bdf $BDF | grep SOC-OS   # expect 1.130.0-a-106-82-...
```
> The current firmware is **already flashed** — same-profile experiments don't need a reflash. Only reflash if you switched firmware and want to restore this RL build.

---

## 3. Profiles (reflash to change port geometry)

Available on the card (`/etc/amd/ainic/$BDF/card_profile.json`):
`meta-roce-2x400G-4` (current, 2 ports), `meta-roce-4x200G-2` (4 ports),
`meta-roce-8x100G-1` (8 ports), `meta-roce-4x100G-1`.

```bash
# reflash a profile (BOTH nodes), then WARM REBOOT both:
nicctl update card profile --profile meta-roce-2x400G-4 --bdf 0000:c1:00.0   # → "warm reboot required"
reboot
```
**Gotchas:**
- After reboot, **hugepages are lost** and the NIC re-enumerates — always redo §4.
- The `mNsetup.sh` scripts in `/root/gaurav/` can be off-by-one on device names (8×100G `m8setup.sh` hardcodes `enp197–204` but the card enumerates `enp196–203`). **Use the corrected `mNfix.sh` approach in §4** instead.
- Port↔plane: 2×400G planes are `enp196s0`=19.1, `enp197s0`=19.2, base `enp195s0f3`=19.0.

---

## 4. Bring-up (after any reboot / profile change) — 2×400G

Run on **both** nodes (perf-3 with local octet **2**, perf-4 with **1**).

```bash
# 4a. Hugepages (lost on reboot) — BOTH nodes
echo 3 > /proc/sys/vm/drop_caches; sleep 1
echo 4096 > /proc/sys/vm/nr_hugepages
mount | grep -q hugetlbfs || mount -t hugetlbfs nodev /dev/hugepages
awk '/HugePages_Free/{print}' /proc/meminfo        # expect 4096

# 4b. Plane bring-up + QoS + 10-bit PCIe tags. LO=2 on perf-3, LO=1 on perf-4:
LO=2   # perf-3;  LO=1 on perf-4
ETH_DEVICE=enp195s0f3
nicctl update qos --classification-type dscp
nicctl update qos dscp-to-purpose  --dscp 46 --purpose rdma-ack
nicctl update qos dscp-to-priority --dscp 46 --priority 2
nicctl update qos dscp-to-priority --dscp 24 --priority 3
nicctl update pipeline rdma path --profile-id 0 --minimum-rto 1000
[ -x /root/nbatchu/10bit_tags_hydra.py ] && /root/nbatchu/10bit_tags_hydra.py
for i in 0 1; do n=$((i+1)); d=enp19$((6+i))s0
  ifconfig $d 19.$n.0.$LO/24 mtu 9000 up
  sysctl -w net.ipv6.conf.$d.disable_ipv6=0; sysctl -w net.ipv6.conf.$d.addr_gen_mode=0
  ip -6 address add 2001:0019:000$n::000$n:$LO/48 dev $d 2>/dev/null
done
ifconfig $ETH_DEVICE 19.0.0.$LO/24 mtu 9000 up
sysctl -w net.ipv4.fib_multipath_hash_policy=1
# (a ready-made version is deployed at /root/gaurav/m2fix.sh — `bash /root/gaurav/m2fix.sh 2` on perf-3, `1` on perf-4)

# 4c. Verify (perf-3)
ip -br addr show | grep -E '19\.[0-2]\.0\.2'                     # 3 addrs: base + 2 planes
ibv_devinfo | grep state                                        # PORT_ACTIVE
for i in 1 2; do ping -c1 -W2 19.$i.0.1 && echo plane$i OK; done # both planes ping perf-4
```

---

## 5. CC / RDMA config (set on BOTH nodes before a run)

```bash
BDF=0000:c1:00.0
# path count: 2 = multipath (= port count), 1 = HOLB (QP pinned to one port)
nicctl update pipeline rdma path -p 0 --count 2 --bdf $BDF
# RCN + omega. RECOMMENDED for 2×400G: omega 7 (reaches line rate; omega 5 caps low QP).
nicctl update pipeline rdma congestion-control profile -p 0 -r enable -o 7 --active-path-per-path-group disable --bdf $BDF
#   no-RCN:  -r disable
nicctl show pipeline rdma congestion-control profile -p 0 --bdf $BDF   # verify
nicctl clear pipeline internal state --bdf $BDF                        # clear before/after each run
```

---

## 6. Run IB (2×400G, 2 planes)

Line rate ≈ **1512 bidir** (~383 G/port). **Use `--run_infinitely` and read steady-state
(~15 s in)** — short fixed `-D` reads catch the ramp and read low.

```bash
BDF=0000:c1:00.0
PL4=19.1.0.1,19.2.0.1        # perf-4 (server) planes
PL3=19.1.0.2,19.2.0.2        # perf-3 (client) planes
# -q <QP>: pick TX/RX so (TX+RX)*QP <= 65435 :  ≤127→-t128 -r383 ; 481–784→-t64 -r64 ; ≥785→-t8 -r7 ; add --noPeak at QP≥512

# SERVER on perf-4 (tmux):
tmux new-session -d -s srv 'numactl --cpunodebind=netdev:enp195s0f3 \
  ib_write_bw -d rocep195s0f3 --use_hugepages -m 4096 -s 1048576 -b -q 64 -x 1 \
  --report_gbits --run_infinitely -D 3 --tclass=96 -t 128 -r 383 --planes=19.1.0.1,19.2.0.1'

# CLIENT on perf-3 → connect to perf-4 MGMT IP (10.30.52.75), NOT a plane IP:
tmux new-session -d -s cli 'numactl --cpunodebind=netdev:enp195s0f3 \
  ib_write_bw -d rocep195s0f3 --use_hugepages -m 4096 -s 1048576 -b -q 64 -x 1 \
  --report_gbits --run_infinitely -D 3 --tclass=96 -t 128 -r 383 --planes=19.1.0.2,19.2.0.2 10.30.52.75 \
  2>&1 | tee /tmp/cli.log'
sleep 15
grep 1048576 /tmp/cli.log | tail -1                       # aggregate BW (col 4)

# per-port TX (2 ports), path→port map, RL status byte:
nicctl show port statistics --rate --bdf $BDF | grep 'Tx bits'
nicctl show rdma queue-pair path --status --bdf $BDF | grep -E 'Port index|effective PWND|RTT'
eth_dbgtool memrd 0x10164c800 8                           # RL RED byte (per-port throttle status)

# cleanup after a run (BOTH nodes):
pkill -9 ib_write_bw; tmux kill-server 2>/dev/null; nicctl clear pipeline internal state --bdf $BDF
```

---

## 7. Rate Limiter (LLC atomic meter) — on perf-3 (sender), needs `nicctl_tot.bin`

```bash
NC=/root/pradeept/nicctl_tot.bin; BDF=0000:c1:00.0
LIF=1     # RDMA traffic lif hw_id (verify: nicctl show rdma queue-pair --bdf $BDF | grep -i lif)
# ENABLE (2×400G: ~383 G/port cap, max-ports 2):
$NC debug update pipeline internal rate-limit --lif $LIF --enable  --rate-bps 383000000000 --burst-bytes 256000 --max-ports 2 --window-lg2 4 --bdf $BDF
# DISABLE:
$NC debug update pipeline internal rate-limit --lif $LIF --disable --rate-bps 1 --burst-bytes 1 --max-ports 2 --window-lg2 4 --bdf $BDF
eth_dbgtool memwr 0x10164c800 8 0 0 0 0 0 0 0 0     # clear RED byte after disabling
```
- RED byte `0x10164c800`: 8 bytes, byte[i]=1 means port i is being rate-limited.
- **⚠️ RL supports only 4 ports (0–3).** Fine for 2×400G and 4×200G; on 8×100G, ports 4–7 get permanently blocked (known bug, owner gborcar). For other rates scale `--rate-bps` (≈95.75 % of per-port line rate) and set `--max-ports` = port count.

---

## 8. Recovery if a node wedges (pingable but SSH hangs)

Seen under extreme load. In-band + BMC SOL login can both hang → power-cycle via BMC:
```bash
H=10.30.52.61; U=admin; P='Pen1nfra$'   # perf-3 BMC
ipmitool -I lanplus -C 17 -H $H -U $U -P "$P" chassis power off ; sleep 20
ipmitool -I lanplus -C 17 -H $H -U $U -P "$P" chassis power on
# (a clean off→on clears a stuck POST better than 'power cycle'). Cold boot ~7 min.
```
After boot: redo §4 (hugepages + bringup). Then sanity: 64-QP bidir should hit ~1512.

---

## 9. Gotchas cheat-sheet
- **Hugepages reset on every reboot** — always redo §4a or `--use_hugepages` fails.
- **8-plane / 8×100G:** `m8setup.sh` device names are off-by-one; RDMA lif = **1** (not 18); RL 4-port bug blocks ports 4–7.
- **Connect to perf-4 via mgmt IP** (10.30.52.75), not a plane/base IP, for the perftest handshake.
- **8-plane / high-QP runs need settle time** — read steady-state, not the first `-D` sample.
- **RCN omega 5 caps low-QP throughput; use omega 7** to reach line rate.
- Reboots on these Kenya nodes occasionally need a full power-drain (off→on) to re-train PCIe.

---
_Compiled by Pradeep's Claude session, 2026-09-08. Current firmware 1.130.0-a-106-82 (pic_rl), profile 2×400G. Ping me when the setup is free to resume HOLB testing._
