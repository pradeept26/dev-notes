# Handoff — PHB OQ-depth collection via capview (f02-2), tclsh read-path broken

**Date:** 2026-07-29
**Node:** `ctheliosp-1b114-f02-2.amd.com` (Vulcano/hydra, build `1.130.0-a-55`, ionic host driver)
**Access:** `ssh prthangar@<node>` (Conductor SUT auth; `sudo` is passwordless). f02-1 perftest binaries are broken (libionic/libibverbs skew, AI-7298).
**Related:** Jira **AI-7298 / AI-7302**; prior handoff `/home/vsampath/memories/HANDOFF_ib_write_bw_gdr_20260729.md` (the q2/q16 bottleneck study). Slack thread **C094YDK9XPW** (Helen Peng, Michael Galles, Vishwas Danivas).

---

## TL;DR

- Helen asked (Slack C094YDK9XPW) to run `vul_phb_oq_depth 0 0 200` in the tcl shell to dump PHB output-queue depth.
- **The tcl shell (diag.exe) does NOT read this card's registers on 1.130.0-a-55** — every CSR read returns `0xdeadbeef`/`0` (the tclsh package's register model mismatches the installed firmware). `vul_phb_oq_depth`'s "all zeros" is a **false read**, not real data.
- **capview is the working register tool.** Re-collected OQ depth via capview's firmware-authoritative indexed method.
- **Result:** at **q2** the egress OQ is mostly empty (mean 0.9 cells, nonzero 29/100); at **q16** it's consistently backed up (mean 79.6, nonzero 100/100). Supports the sender-side TX-feeding limit (q2 under-feeds the wire), not egress/PHB congestion.
- Result posted to Slack channel C094YDK9XPW (new message `p1785325827617069`). Raw samples: `/home/prthangar/oqdepth_f02-2/oq3_{q2,q16}.txt`.
- Setup left clean: no ib procs, no config changes (only CSR reads + a harmless status-mux index write).

---

## Card / RoCE / GPU / UUID mapping (f02-2)

| RoCE dev | fn BDF | card BDF (`-b`) | PAL_CARD_UUID | GPU (`--use_rocm`) | role in loopback |
|---|---|---|---|---|---|
| roceP1p3s0f3 | 0001:03:00.3 | 0001:01:00.0 | `42424650-5132-3630-3930-303741000000` | GPU0 = `--use_rocm=0` | **sender/client** |
| roceP2p3s0f3 | 0002:03:00.3 | 0002:01:00.0 | `42424650-5132-3630-3930-303539000000` | GPU1 = `--use_rocm=1` | **receiver/server** |
| roceP3p3s0f3 | 0003:03:00.3 | 0003:01:00.0 | `42424650-5132-3630-3930-303439000000` | GPU2 | idle |
| roceP4p3s0f3 | 0004:03:00.3 | 0004:01:00.0 | `42424650-5132-3630-3930-303538000000` | GPU3 | idle |

UUID prefix is constant `42424650-5132-3630-3930-XXXXXX000000`. RoCE GID **index 2** = IPv6 (use `-x 2`).

---

## Finding 1 — tclsh (diag.exe) register reads are broken on this build (KEY)

Every `csr_read` / `csr_read_field` through diag.exe returns `0xdeadbeef` (PCIe poison = unmapped/failed read); `vul_phb_oq_depth 0 0 200` prints all-zero because its underlying read fails. Proven by cross-check against capview under identical q2/q16 load:

| register | capview (known-good) | diag.exe tclsh |
|---|---|---|
| `pt0_pt_ptd_CNT_ma`.sop | increments live (~613M pkts/2s) | `0xdeadbeef` |
| `ph0_phb_sta_oq_depth` | non-zero under load | `0` |

Root cause: the tclsh package (`/apps/shared/tclshl`, diag.exe + asic_src from a ~Dec-2025 build) has a register model that does not match 1.130.0-a-55 firmware addressing on the x86 PAL path. **Do not trust diag.exe register reads on this node.** To make it work you'd need a tclsh built from the matching fw tree, or run it on the SoC console.

### tclsh setup that WAS done (for reference; reads still broken)
- Source tree: `/apps/shared/tclshl/` is NFS (`noexec`, owned by `maeaswar`) → copied to local `/tmp/prt_tclsh/` and run from there.
- Launcher gotchas (baked into `/tmp/prt_tclrun.sh` and `/tmp/prt_tclsh.sh`):
  - **Do NOT** put `depend_libs/lib64` on `LD_LIBRARY_PATH` — its ancient glibc breaks every subprocess (bash/file/diag.exe). Use only `asic_lib` + `depend_libs/mtp_hack` + `/usr/lib64/ainic/vulcano/rudra/hydra`.
  - `libnic_ipc.so` lives at `/usr/lib64/ainic/vulcano/rudra/hydra/` (not `/usr/lib` as the stock `tcl-host.sh` hardcodes) → use as `LD_PRELOAD`.
  - Copy `libpython2.7.so.1.0` to `/usr/lib64` once.
  - In-tcl init: `set ::x86_build 1; set ::VEL_SHELL 0; set ::tcl_interactive 0; source .../.tclrc.diag.vul`. `diag_open_pcie_pal_if` (card attach) only runs when `x86_build` is set.
  - **Card selection = `PAL_CARD_UUID`** (or `PAL_RESDEV_BDF`), external to the tcl command. The `chip_id`/`inst` args in `vul_phb_oq_depth <chip> <inst> <sample>` are always 0 (single opened chip / only 1 PHB inst); they do NOT pick the card. Default (no UUID) = card `0001`.

---

## Finding 2 — capview is the working tool; OQ-depth authoritative method

capview: `/sbin/capview -f /etc/amd/ainic/vulcano/rudra/hydra/capviewdb.bin`, card via `PAL_CARD_UUID`. Verbs: `find read info fset set show write td`.

OQ depth is an **indexed** register pair (from firmware `vulcano_tm_get_oq_depth()` in `nic/sdk/rtos-shared/src/lib/asicpd/vulcano/tm/vulcano_tm_utils.c`):
1. Write index: `fset pbe_cfg_sta_oq_idx .prt=<port> .oq=<queue>`  ← **space before each `.field` is REQUIRED** (`pbe_cfg_sta_oq_idx.prt=0` with no space fails: "register does not exist").
2. Read value: `read pbe_sta_oq` → field **`depth` [14:0]** (15-bit, cells). The value is the LAST token after `depth:` (`$NF`), NOT the bitrange label `[14:0]`.

`pbe_cfg_sta_oq_idx` fields: `prt`[2:0], `oq`[8:3].
`pbe_sta_oq` fields: active_list_tail[76], active_list_head[75], tail_ptr1[74:60], head_ptr1[59:45], tail_ptr0[44:30], head_ptr0[29:15], **depth[14:0]**.

PB port map (`nic/sdk/lib/qos/include/qos_vulcano.h`): **0 = uplink (wire egress)**, 1 = unmapped, 2–3 = UDMA, 4–5 = P4. Active egress queue for this test = **port 0, oq 3** (tclass=128; matches asicmon XOFF on queue index 3).

> Avoid the packed register `ph0_phb_sta_oq_depth` / `ph1_...` — its 255-bit `value` field is not cleanly per-queue-decodable (it packs head/tail pointers, not just depth; early attempts mis-read ~0x2a80 at a non-16-bit-aligned offset). Use the indexed `pbe_sta_oq.depth` instead.

---

## Finding 3 — Results: q2 vs q16 OQ depth (port 0, oq 3)

100 samples under steady `-D` GDR load, capview indexed method:

| condition | goodput | OQ depth (cells): mean / max / nonzero |
|---|---|---|
| idle | — | 0 / 0 / 0/40 |
| **q2** | 569 Gb/s (bimodal **low** state) | **0.9** / 34 / **29/100** — mostly empty |
| **q16** | 774 Gb/s (line rate) | **79.6** / 87 / **100/100** — consistently backed up |

**Interpretation:** at q2 the sender under-feeds, so the egress OQ drains/starves (wire idle); at q16 the OQ stays full at line rate. Egress/PHB is not the bottleneck — consistent with the sender-side TX-feeding (per-QP TX concurrency / path-spreading) limit from the prior handoff. Note the q2 run landed in the ~570 low state (bimodal); a q2 high-state (~774) sample was not captured — worth doing to see if OQ occupancy tracks the high state.

### asicmon card-selection cross-check (proves PAL_CARD_UUID works)
Under q16, only the sender (P1) and the no-UUID **default** show XOFF on queue 3 (94–97%); P2/P3 are flat. Default no-UUID attaches to card `0001`. `asicmon`: `PAL_CARD_UUID=<uuid> asicmon` (signals: `XOFF:` per-queue, `PBC: sop=`, `DeParser: dpa_drop=`).

---

## Commands reference

### IB q2/q16 GDR loopback (roceP1→roceP2)
```bash
BIN=/home/visampath/ib_write_bw; QP=2   # or 16
pkill -f ib_write_bw; sleep 1
# server = roceP2 / GPU1
$BIN -d roceP2p3s0f3 -i 1 -x 2 --tclass=128 -F --report_gbits -s 8388608 -D 40 -q $QP --use_rocm=1 &
sleep 3
# client = roceP1 / GPU0 (OOB over IPv4 loopback; -x 2 for IPv6 RoCE GID; do NOT use --ipv6-addr)
$BIN -d roceP1p3s0f3 127.0.0.1 -i 1 -x 2 --tclass=128 -F --report_gbits -s 8388608 -D 40 -q $QP --use_rocm=0
```

### OQ depth via capview (WORKING)
```bash
UUID=42424650-5132-3630-3930-303741000000   # roceP1 sender
DB=/etc/amd/ainic/vulcano/rudra/hydra/capviewdb.bin
# single (port,queue) depth:
printf 'fset pbe_cfg_sta_oq_idx .prt=0 .oq=3\nread pbe_sta_oq\n' | PAL_CARD_UUID=$UUID capview -f $DB | awk '/depth:/{print $NF}'
# N samples of the active queue in one session:
{ echo 'fset pbe_cfg_sta_oq_idx .prt=0 .oq=3'; for i in $(seq 100); do echo 'read pbe_sta_oq'; done; } \
  | PAL_CARD_UUID=$UUID capview -f $DB | awk '/depth:/{print $NF}'
# scan all ports/oqs: loop prt 0..5, oq 0..15 with fset+read
```

### PCIe latency bucket (nicctl, host-side — populates only under load)
```bash
nicctl show pcie internal latency-bucket -r -b 0001:01:00.0   # -r read, -w write, -d detail, -j json
```

---

## Artifacts on f02-2

- **Results:** `/home/prthangar/oqdepth_f02-2/oq3_q2.txt`, `oq3_q16.txt` (100 depth samples each, plain integers).
- capview raw OQ samples: `/tmp/oq_q{2,16}_ph0.txt`, `/tmp/scan_out.txt`.
- Working helper (capview): `/tmp/prt_capoq.sh`, `/tmp/prt_decode.py`.
- IB drivers: `/tmp/prt_collect.sh`, `/tmp/prt_oqcollect.sh`, `/tmp/prt_qN_capture.sh`.
- tclsh (BROKEN reads, kept for reference): `/tmp/prt_tclsh/` (diag.exe tree), `/tmp/prt_tclrun.sh` (batch), `/tmp/prt_tclsh.sh` (interactive; run with `ssh -t`).
- asicmon snapshots: `/tmp/prt_am_*.txt`, `/tmp/prt_q{2,16}_asicmon.txt`.

---

## Open items / next steps

1. **q2 high-state OQ sample** — the q2 run captured was the ~570 low state (bimodal). Capture a q2 ~774 high-state run and compare OQ depth (does it match q16 ~80 cells?) to tie OQ occupancy to the path-spreading lottery.
2. **Fix tclsh** if `vul_phb_oq_depth` output is specifically needed — build the tclsh package from the 1.130.0-a-55 tree (or run diag.exe on the SoC console) so its reg-model matches; otherwise standardize on capview.
3. Correlate high vs low q2 runs with QP→path assignment (prior-handoff open item #1) — OQ depth is now a usable live signal for that.
