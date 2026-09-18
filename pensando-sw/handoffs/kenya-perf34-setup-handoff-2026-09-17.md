# kenya perf-3 / perf-4 Testbed — Setup & Operations Handoff

**Owner:** Pradeep Thangaraju · **Date:** 2026-09-17
**Purpose:** Everything a fresh session needs to access, (re)flash, bring up, run RDMA traffic on,
and recover the kenya perf-3/perf-4 Vulcano AI-NIC testbed.

---

## 1. Nodes & access

| Node | Role | Mgmt IP | Planes (LO octet) | Creds |
|------|------|---------|-------------------|-------|
| perf-3 (kenya-1354, FPF26040014) | **client / sender** | `10.30.52.66` | 19.1–4.0.**2** (LO=2) | root / docker |
| perf-4 (kenya-3190, FPF26040001) | **server / receiver** | `10.30.52.75` | 19.1–4.0.**1** (LO=1) | root / docker |

- **Common:** BDF `0000:c1:00.0`, ASIC **vulcano**, pipeline **hydra**, RDMA dev `rocep195s0f3`, base netdev `enp195s0f3`.
- SSH pattern used throughout: `sshpass -p docker ssh -o StrictHostKeyChecking=no root@<ip> '<cmd>'`.
- **Out-of-band (perf-3):** BMC `10.30.52.61` `admin`/`Pen1nfra$` — **ipmitool needs `-I lanplus -C 17`** (cipher 3/1 fail). APC PDU `10.30.52.57` port 19, apc/apc. NIC console (Saraceno): Vulcano `telnet 10.30.52.56 2002`, SuC `telnet 10.30.52.56 2003`. Switch = Micas `10.30.52.100` port 1/16 admin/Micas123.
- Full node YAML: `~/dev-notes/pensando-sw/hardware/vulcano/data/kenya-1354.yml` (perf-4 = `kenya-3190.yml`).

## 2. Current state (as of 2026-09-17, may change)

- **Firmware:** `1.130.0-a-129-30-g81b19a8294d` = ToT (`origin/1.130-a`, a-129) + 26 RL commits from Gaurav's `meter_rl_llc` (PR #119731, LLC-meter rate-limiter + S2 scatter fix).
- **Profile:** `meta-roce-4x200G-2` (4 planes UP, bidir 800G/dir = 1600G theoretical).
- **nicctl:** our RL-capable build is installed as `/usr/sbin/nicctl` on **both** nodes (has `debug update pipeline internal rate-limit`). Stock a-129 nicctl lacks the RL commands.
- Left clean: RL disabled, no traffic, all ports/planes up.
- ⚠️ **If you need a different fw/profile, reflash (§4). Ping Pradeep first if you want to preserve this RL build.**

## 3. Available card profiles (packaged in fw)
`nicctl show card profile --all` →  `default` (1×400G-4), `meta-roce-4x200G-2`, `meta-roce-4x100G-1`, `meta-roce-2x400G-4`, `meta-roce-8x100G-1`.

## 4. How to load an image (firmware + host tools)

### 4a. Get artifacts
- **Official hourly bundle** (host tools + stock fw): `/vol/builds/hourly/<VER>/rudra-bundle/release-artifacts/hydra/vulcano/ainic_bundle_<VER>.tar.gz` (e.g. `1.130.0-a-129`). Contains nested `host_sw_pkg.tar.gz` (install.sh + nicctl deb + ionic drivers + perftest) and `firmware/ainic_fw_vulcano.tar`.
- **Custom fw** (this session): built `ainic_fw_vulcano.tar` + `nicctl.bin` — see §9.

### 4b. Flash flow (what worked, low-risk)
`install.sh` is **host-only** (installs ionic driver + perftest + nicctl; NO fw flash / NO `--reset`). Flash fw separately.
```bash
# stage on each node (/root/rl-tot/): ainic_fw_vulcano.tar, nicctl.bin, host_sw_pkg.tar.gz
tar -xf host_sw_pkg.tar.gz && cd host_sw_pkg && ./install.sh -y   # a-129 drivers + perftest + nicctl
nicctl update firmware -i /root/rl-tot/ainic_fw_vulcano.tar        # (no --reset; or add --all)
nicctl reset card                                                  # activate  (perf-3 has wedged on --reset FLASH; plain reset OK here)
cp /root/rl-tot/nicctl.bin /usr/sbin/nicctl                        # overlay our RL nicctl (needed for RL cmds)
nicctl show version firmware | grep -i soc-os                      # verify version
```
> **Lower-risk alternative** if you also change profile: flash **without `--reset`**, set the profile (§5), then a **single reboot** activates both (avoids the perf-3 `--reset` wedge). Profile change alone does NOT need a reboot (auto-commissions).

## 5. Switch profile (e.g. to 4×200G)
```bash
nicctl update card profile --profile meta-roce-4x200G-2 --bdf 0000:c1:00.0   # both nodes
# Rescan→Commission→Successful. On a-129 this enumerated the 4 plane netdevs WITHOUT a reboot.
# (older builds may say "warm reboot required" → reboot)
```

## 6. Bringup (both nodes, after profile/flash/reboot)
```bash
echo 3 > /proc/sys/vm/drop_caches; echo 4096 > /proc/sys/vm/nr_hugepages   # hugepages LOST on reboot!
mount -t hugetlbfs nodev /dev/hugepages 2>/dev/null
for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > $c; done
cd /root/gaurav && bash m4setup.sh          # per-node: perf-3 uses .2, perf-4 uses .1 (each script hardcoded)
echo 4 > /sys/class/infiniband/rocep195s0f3/mrc_nports   # NOTE: a-129 driver = mrc_nports (was puec_nports pre-rename)
nicctl update multiplane --bdf 0000:c1:00.0
```
Verify: `ip -br addr show enp196s0..enp199s0` (4 planes UP w/ 19.N.0.LO), `ibv_devinfo -d rocep195s0f3 | grep PORT_ACTIVE`, cross-plane ping perf-3→perf-4 all 4 planes.

## 7. Run RDMA traffic (multiplane, 4×200G)
```bash
# RDMA lif for RL = hw_id 1 (nicctl show lif --json). Perftest binary: /usr/bin/ib_write_bw (a-129, supports --planes).
# server (perf-4) detached:
numactl --cpunodebind=netdev:enp195s0f3 /usr/bin/ib_write_bw -d rocep195s0f3 --use_hugepages \
  -m 4096 -s 1048576 -q <QP> -x 1 --report_gbits --planes=19.1.0.1,19.2.0.1,19.3.0.1,19.4.0.1 \
  -D 20 --tclass=96 -t 32 -r 32 -b            # >=729 QP: use -t 8 -r 7 (CQ cap (TX+RX)*QP<=65435); add --noPeak >=512
# client (perf-3): same but --planes=19.N.0.2 ... and trailing dest = 10.30.52.75 (mgmt IP for connection setup)
```
Parse: `grep 1048576 | tail -1 | awk '{print $4}'` = BW average Gbps.

## 8. RL (LLC-meter rate-limiter) — for HOLB work
```bash
# Standard config (reaches line rate on the scatter build): burst 200000 / window-lg2 4
nicctl debug update pipeline internal rate-limit --lif 1 --enable \
  --rate-bps 199000000000 --burst-bytes 200000 --max-ports 4 --window-lg2 4 --bdf 0000:c1:00.0
nicctl debug update pipeline internal rate-limit --lif 1 --disable --max-ports 4 --bdf 0000:c1:00.0   # off
nicctl show pipeline internal rate-limit --bdf 0000:c1:00.0        # exceed_count/rl_spec_fail/enabled
nicctl clear pipeline internal state --bdf 0000:c1:00.0            # reset QP/anomaly state (do NOT run with active traffic)
```
- CC profile: `nicctl update pipeline rdma congestion-control profile -p 0 -r <enable|disable> -o <omega> --active-path-per-path-group <enable|disable> --bdf ...` (RCN off = `-r disable`; omega 7 recommended, ω5 caps low-QP).
- Path count: `nicctl update pipeline rdma path -p 0 --count <1|4> --bdf ...` (count 1 = HOLB generator; path×QP ≤ 8192 → count 4 caps QP at 2048).
- **Live port-shut** (fault-tolerance tests): `nicctl update port -p <port-uuid> -a down|up --bdf ...`. Ports = `eth1/1/1,3,5,7` = plane 1–4 (UUIDs from `nicctl show port`; perf-3 prefix `049081a7-7120-...-0000110100{01,03,05,07}`). **`ip link set <netdev> down` does NOT drop the RDMA plane** — must use nicctl port. For live BW during shut use `ib_write_bw --run_infinitely -D 5` (per-interval BW; without -D it's cumulative and masks the drop).
- Config note: **burst 200K/win4 is build-dependent** — on this scatter build it beats 256K/win10 (which dips ~2% @512QP). Verify per build.

## 9. Build (fw + host nicctl) — if you need a new build

Workspace `/ws/pradeept/ws/usr/src/github.com/pensando/sw-1`. RL branch line = Gaurav `meter_rl_llc` (PR #119731) rebased onto ToT (local `pradeept/rl-tot`).
```bash
# fresh container (see /dev-container skill): submodule update --init --recursive (host),
#   then: cd nic && make docker/background-shell ; docker exec <ct> git config --global --add safe.directory '*'
#   then: docker exec <ct> bash -c 'cd /sw && make pull-assets'
#   (if ws-tools fails on gopathwalk patch: `git checkout -- vendor/golang.org/x/tools/internal/gopathwalk/walk.go` then re-run)
#   (if Zephyr cmake enum error after branch switch: rm -rf /sw/platform/rtos-sw/external/ainic-rtos/build)
docker exec <ct> bash -c 'cd /sw && make clean && make -f Makefile.ainic clean'
docker exec -w /sw <ct> make -f Makefile.build build-rudra-vulcano-hydra-ainic-fw        # -> /sw/ainic_fw_vulcano.tar
docker exec -w /sw <ct> make -C nic PIPELINE=rudra ASIC=vulcano P4_PROGRAM=hydra PLATFORM=hw ARCH=x86_64 nicctl.bin
#   nicctl.bin -> nic/build/x86_64/hw/rudra/vulcano/out/nicctl_bin/nicctl.bin
```
fw + nicctl MUST come from the same tree (shared IPC struct `pic_rl_params_t`). Also install matching a-129 host tools/drivers/perftest from the hourly bundle (§4).

## 10. Recovery (perf-3 wedge)

Host pingable but SSH + BMC SOL login hang = hard memory pressure (getty/PAM can't fork). Must power-cycle:
```bash
ipmitool -I lanplus -C 17 -H 10.30.52.61 -U admin -P 'Pen1nfra$' chassis power off ; sleep 20
ipmitool -I lanplus -C 17 -H 10.30.52.61 -U admin -P 'Pen1nfra$' chassis power on
```
- **Warm `power cycle` does NOT clear a stuck POST — use clean off→(20s)→on.** APC AC-drain (PDU 10.30.52.57 outlet 19) if BMC also unresponsive.
- Cold boot ~7 min to ping (512 GB memory training, silent console). NIC PCIe re-enumerates clean at c1:00.0.
- After boot: re-bringup (§6) — **hugepages are lost on reboot.** Sanity: 8-QP bidir 4-plane ~1353 Gbps = healthy.
- `nicctl reset card` can HANG the host; the NIC `--reset` FLASH has wedged perf-3 before → prefer no-`--reset` + reboot.

## 11. Skills to reference (this repo's `.claude/skills/`)
- **`/debug-meta-roce`** — RDMA/HOLB debugging (anomalies, stuck-test workflow, nicctl cmd reference). Reads `nic/rudra/src/hydra/p4/p4plus-16/meta_roce/docs/06-debugging.md` + `10-performance-debugging.md`.
- **`/dev-container`** — fresh Docker container (submodule update, launch, git-ownership fix, pull-assets).
- **`/full-build`** — build fw/gtest/dol (`/full-build vulcano hydra ainic-fw`).
- Firmware install procedure ref: `~/systest-agentq/projects/ainic/e2e/skills/install-firmware.md`.
- Build/test details also in project memory `MEMORY.md` (build commands, container mgmt).

## 12. Reports & prior handoffs (context)
- **This session's RL work:** http://srv6.pensando.io/systest/agentq/rl-scatter-holb-pradeept/ (HOLB 1a/1b/1c + on/off sweep on ToT+scatter). Raw CSVs + harness (`lib.sh`, `run_1ab.sh`, `run_1c.sh`, `run_1a_ppgen.sh`) in that dir and `~/dev-notes/pensando-sw/handoffs/RL-scatter-*-2026-09-17.*`.
- Prior HOLB (a-115): http://srv6.pensando.io/systest/agentq/phase1-holb-rl-pradeept/ · 2×400G: `holb-2x400-pradeept/`.
- Prior handoffs in `~/dev-notes/pensando-sw/`: `session-handoff-holb-rl-2026-09.md`, `RL-multipath-perf-rootcause-2026-09-15.md`, `4k-qp-perf-analysis-handoff.md`, `kenya-2x400-handoff.md`.
- Publish a report: copy HTML as `index.html` into `/vol/systest/agentq/<name>/` → served at `http://srv6.pensando.io/systest/agentq/<name>/`.

## 13. Gotchas checklist
- Hugepages lost on reboot → reconfigure before any `--use_hugepages` run.
- a-129 driver renamed `puec_nports`→`mrc_nports` (sysfs + perftest). Use the a-129 `/usr/bin/ib_write_bw`.
- RL lif = **hw_id 1** on 4×200G a-129 (older notes said 18).
- perftest CQ cap: `(TX+RX)×QP ≤ 65435` → QP≥729 use `-t 8 -r 7`.
- Live port-shut: nicctl port (not netdev); `--run_infinitely -D 5` for per-interval BW.
- `nicctl clear pipeline internal state` with active traffic can stick QPs.
- 8×100G RL is BROKEN (4-port hardcode, ports 4–7 blocked) — see `session-handoff-holb-rl-2026-09.md` §4. RL only valid on 4×200G / 2×400G.
- `m8setup.sh` off-by-one for 8×100G — use `/root/gaurav/m8fix.sh`.
