# Handoff — LLC-Meter RL: nicctl `err 95` fix + HOLB verification (a-119)

**Author:** Pradeep (Claude session) · **Date:** 2026-09-10
**Testbed:** kenya perf-3 (`10.30.52.66`) / perf-4 (`10.30.52.75`), 4×200G
**For:** teammate taking over RL testing on the a-119 byte-accurate build

---

## 1. TL;DR

- **Root-caused and fixed** the `nicctl ... err 95` that blocked enabling the LLC-meter
  rate-limiter (RL) on the a-119 build. Root cause: **PIC_RL opcodes were registered in
  `zrpc.c` but not `tawk.c`**; nicctl's `debug/show pipeline internal` commands ride the
  **TAWK** transport, so dispatch returned `OP_NOT_SUPPORTED`. Lost in the a-106→a-119 port.
- **RL enable now works** on both nodes, and **HOLB recovery is verified**:
  path-1, 9 QP, 4×200G, unidirectional → **RL off 547.65 Gbps → RL on 765.76 Gbps (+40%)**.
- **Fixes committed and pushed** to my fork (see §3). Currently-flashed firmware on the
  nodes also has debug traces (not in the commit) — see §5.
- **Two testbed caveats** you must know before running: the perftest `puec_nports`→`mrc_nports`
  mismatch (§6) and the byte-accurate RL tuning `window-lg2 10 / 195G` (§7).

---

## 2. Root cause & the fix (what changed and why)

nicctl → `debug update pipeline internal rate-limit` uses **TAWK** IPC, not fwctl/ZRPC.
A new nicmgr opcode must be registered in **BOTH** `tawk.c` and `zrpc.c`. The RL feature
registered PIC_RL only in `zrpc.c` → TAWK dispatch miss → `err 95`, handler never reached.

**Commit `eaceb4ef6c5` — 4 files:**
| File | Change |
|---|---|
| `platform/rtos-sw/modules/nicmgr/src/tawk.c` | **THE FIX** — added `pic_rl_upd/get_req_handler` wrappers + `DECLARE_IPC_CMD` entries in `internal_ipc_cmd_table` (mirrors AUTO_CLEAR) |
| `platform/rtos-sw/modules/nicmgr/src/zrpc.c` | PIC_RL attrs → `ZRPC_CMD_ATTR_DEBUG_WRITE/DEBUG_READ` (match other internal cmds; correct fwctl scope advertisement) |
| `nic/sdk/lib/nic_ipc/fwctl_ipc_impl.cc` | add `PIC_RL_UPDATE` to the scope-2 (DEBUG_WRITE) list |
| `nic/rudra/src/hydra/p4/p4plus-16/meta_roce/tx/meta_roce_tx_s6.p4` | gate byte-accurate RL meter table on `pred.retx_or_cwnd_retry == 0` (skip metering on retx), nested under `add_headers` |

Debugging that was **ruled out** (don't re-chase): nicctl opcode skew, NULL `pic_rl_update`
callback, stale build objects, flash/partition/boot mismatch, fwctl/pds_fwctl scope, generic
fwctl framework. All red herrings — the transport was TAWK, not fwctl. Confirmation method:
a firmware trace at the ipc handler never fired, and one at the fwctl RPC handler never fired
even for *working* commands → proved TAWK path → `grep -c PIC_RL tawk.c zrpc.c` (0 vs 2).

---

## 3. Code location — fork / branch / commit

- **Fork:** `git@github.com:pradeept26/sw.git` (https://github.com/pradeept26/sw)
- **Branch:** `pradeept/gborcar-new`  (Gaurav's `meter_rl_llc` rebased onto a-119 + byte-accurate + this fix)
- **Fix commit:** `eaceb4ef6c5` — "meta_roce RL: register PIC_RL over TAWK transport (fix nicctl err 95)"
- **Parent:** `99c882a7c0d` (byte-accurate S6 RAW-hazard fix), on tag `1.130.0-a-119`

```bash
git clone git@github.com:pradeept26/sw.git
cd sw && git checkout pradeept/gborcar-new   # eaceb4ef6c5 at HEAD
git submodule update --init --recursive
```

---

## 4. Build

Inside the dev docker (`cd nic && make docker/background-shell`; `git config --global --add safe.directory /sw`; `make pull-assets`):

```bash
# Firmware (P4 + RTOS/nicmgr):
make -f Makefile.build build-rudra-vulcano-hydra-ainic-fw
#   -> /sw/ainic_fw_vulcano.tar   (the flash artifact)
# If Zephyr cmake cache is stale after branch switch:
#   rm -rf /sw/platform/rtos-sw/external/ainic-rtos/build

# nicctl (host x86 tool with the fwctl_ipc_impl.cc scope fix):
make -C nic PIPELINE=rudra ASIC=vulcano P4_PROGRAM=hydra PLATFORM=hw ARCH=x86_64 nicctl.bin
#   -> nic/build/x86_64/hw/rudra/vulcano/out/nicctl_bin/nicctl.bin
```

Flash both partitions (Kenya `--all` needs `--reset`; ~11 min + reset):
```bash
scp ainic_fw_vulcano.tar root@<node>:/var/tmp/fw.tar
ssh root@<node> 'nicctl update firmware -i /var/tmp/fw.tar --all --reset'
# reset severs ssh mid-flash; run detached + log to a file on the host and poll for "Successful/EXITCODE".
```

---

## 5. Current testbed state (as left)

- **Both nodes:** firmware `1.130.0-a-119-20-g99c882a7c0d-dirty`, profile `meta-roce-4x200G-2`,
  path-1, RCN ω7, active-path disabled, **multiplane up (00001111)**, **RL disabled**, traffic stopped.
- **On each node:**
  - `/root/nicctl_fix2.bin` — the fixed nicctl (has the RL command working)
  - `/root/ib_write_bw_mrc` — perftest patched to read `mrc_nports` (see §6)
- **IMPORTANT:** the flashed firmware was built from the tree **with two debug traces**
  (`PIC_RL_DIAG` in ipc.c, `PIC_RL_DIAG2` in fwctl_vdev.c) that are **NOT** in commit `eaceb4ef6c5`
  (I reverted them for a clean commit). Functionally identical for RL. For a production/clean
  build, rebuild from `eaceb4ef6c5` and reflash. The debug traces just add noisy `<err>` lines
  in `nicctl show card logs`.

Creds: `root/docker`. BMC perf-3 `10.30.52.61` admin/`Pen1nfra$`. Connect to perf-4 for perftest via mgmt IP `10.30.52.75`.

---

## 6. ⚠️ Perftest gotcha (MUST fix before any multiplane run)

The installed `/usr/bin/ib_write_bw` (and all 1.125-era bundles on the box) read
`/sys/class/infiniband/<dev>/puec_nports`. The **a-119 driver renamed it to `mrc_nports`**
(rename puec→mrc commit). So stock perftest sees **0 planes** → collapses to one plane
(**176 Gbps, MTU 1024**) with `WARNING: Number of puec planes (4) does not match device configuration (0)`.

**Workaround used (already deployed at `/root/ib_write_bw_mrc`):** binary-patch a copy —
```bash
python3 -c 'd=open("/usr/bin/ib_write_bw","rb").read(); \
  open("/root/ib_write_bw_mrc","wb").write(d.replace(b"puec_nports", b"mrc_nports\x00"))'
chmod +x /root/ib_write_bw_mrc     # null truncates the sysfs path to .../mrc_nports
```
**Proper fix:** use a 1.130/a-119 perftest (built from the same tree as the driver). Ask Gaurav
which perftest build matches a-119.

After the patch: multiplane spreads across all 4 planes, MTU negotiates to 4096, baseline ~548 Gbps.

---

## 7. ⚠️ Byte-accurate RL tuning (differs from the old a-106 flow!)

The byte-accurate meter (S6) charges full **wire** bytes (payload + meta_roce_hdr + outer
Eth/IP/UDP + ICRC), not payload-only. Consequences vs the old a-106 `191.5G / window-lg2 4`:

- **`window-lg2` must be 10 (~1µs), NOT 4 (~14ns).** window-4 makes throttling bursty →
  **QP stall**: `requester RX error-disabled 0xc`, `ack_msn not advancing`, `spec_failure
  rollback`, perftest `Failed to complete run_iter_bw (scnt≫ccnt)`.
- **rate must be ~195G/port, NOT 191.5G.** With wire-byte accounting, 191G over-throttles →
  same stall. 195G works. (300G = above line rate = no throttle = equals baseline; used to prove
  it's over-throttle, not a metering bug.)
- **`--burst-bytes 1048576`** (1MB) beats 256000.

This is the whole point of the byte-accurate change — the RL rate can now be set toward true
per-port line rate. **Still-open:** find the exact max rate that recovers HOLB without stall
(195 works, 191 stalls; sweep 195–200 and characterize).

---

## 8. HOLB test procedure (working, reproducible)

Bring-up after any reboot (m4setup misses two things — base netdev + multiplane):
```bash
# BOTH nodes. LO=2 on perf-3, LO=1 on perf-4.
echo 4096 > /proc/sys/vm/nr_hugepages
for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance >$c; done
bash /root/gaurav/m4setup.sh                       # planes/QoS/path
for i in 0 1 2 3; do n=$((i+1)); ifconfig enp19$((6+i))s0 19.$n.0.$LO/24 mtu 9000 up; done
ifconfig enp195s0f3 19.0.0.$LO/24 mtu 9000 up       # base netdev — RoCE PORT_ACTIVE follows this
echo 4 > /sys/class/infiniband/rocep195s0f3/mrc_nports    # a-119 multiplane (m4setup line is commented out)
/root/nicctl_fix2.bin update multiplane --bdf 0000:c1:00.0
# verify: nicctl show multiplane -> 00001111 ; ibv_devinfo -> PORT_ACTIVE (4)
```

HOLB config (BOTH nodes):
```bash
BDF=0000:c1:00.0; NC=/root/nicctl_fix2.bin
$NC update pipeline rdma path -p 0 --count 1 --bdf $BDF                                  # path-1 = HOLB
$NC update pipeline rdma congestion-control profile -p 0 -r enable -o 7 \
   --active-path-per-path-group disable --bdf $BDF
$NC clear pipeline internal state --bdf $BDF
```

RL enable (BOTH nodes, working config):
```bash
$NC debug update pipeline internal rate-limit --lif 18 --enable \
   --rate-bps 195000000000 --burst-bytes 1048576 --max-ports 4 --window-lg2 10 --bdf $BDF
# disable: same cmd with --disable
```

Run (server on perf-4, client on perf-3; **use the patched perftest**):
```bash
# server (perf-4), detached:
numactl --cpunodebind=netdev:enp195s0f3 /root/ib_write_bw_mrc -d rocep195s0f3 --use_hugepages \
  -m 4096 -s 1048576 -q 9 -x 1 --report_gbits --planes=19.1.0.1,19.2.0.1,19.3.0.1,19.4.0.1 \
  -D 20 --tclass=96 -t 32 -r 32
# client (perf-3), connect to mgmt IP 10.30.52.75:
numactl --cpunodebind=netdev:enp195s0f3 /root/ib_write_bw_mrc -d rocep195s0f3 --use_hugepages \
  -m 4096 -s 1048576 -q 9 -x 1 --report_gbits --planes=19.1.0.2,19.2.0.2,19.3.0.2,19.4.0.2 \
  -D 20 --tclass=96 -t 32 -r 32 10.30.52.75
```

**Verified result:** RL off **547.65**, RL(195G,win10) **765.76** Gbps (+40%). `pkill -x ib_write_bw_mrc` between runs; clear state each run.

---

## 9. Open items / next steps

1. **Rate sweep with byte-accurate:** characterize max HOLB-recovery rate without stall
   (195 works, 191 stalls). Try 196–200, and re-check the `-b` bidirectional numbers to line up
   with the old a-106 figures (path-1 9QP: 1123→1507 were bidirectional).
2. **Proper a-119 perftest** that reads `mrc_nports` (replace the binary-patch hack).
3. **Full matrix** per the prior report: path-4 self-balance, live-shut sweep, 8×100G
   (8×100G RL peek recovery is hardcoded 4-port — separate parked work, see `project_rl_8x100_genpeek_parked.md`).
4. **PR** commit `eaceb4ef6c5` → decide target (Gaurav's `meter_rl_llc` line / master CP).
5. Optional: re-add the two debug traces if you want handler-reached visibility during testing
   (they were in the flashed image; reverted in the commit).

## 10. References
- Prior HOLB/RL report: `~/dev-notes/pensando-sw/session-handoff-holb-rl-2026-09.md`
- 2×400G runbook: `~/dev-notes/pensando-sw/kenya-2x400-handoff.md`
- Claude memory: `feedback_nicctl_tawk_vs_zrpc_transport.md`, `project_rl_byteaccurate_holb_verified.md`
