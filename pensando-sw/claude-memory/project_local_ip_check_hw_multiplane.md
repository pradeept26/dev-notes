---
name: RDMA local-IP-check HW multiplane validation (kenya-perf3/4)
description: HW multiplane test of the Hydra RDMA local-IP admission check — positive path validated on kenya-perf3/4 back-to-back 4x200G; drop path not testable there (with reusable testbed facts)
type: project
originSessionId: 985b82a6-338f-4c36-becf-d4fe3bc02d7f
---
Feature: RDMA local-IP admission check (Hydra/Meta-RoCE, PR #120693). Validated multiplane on
kenya-perf-3 (10.30.52.66, client) / perf-4 (10.30.52.75, server), **back-to-back 4x200G**
(4 direct per-plane cables, NO switch — Micas 10.30.52.100 is mgmt only), fw
`1.130.0-a-92-247-gba4ec974ba6` (ToT 71019d8ae1e + our 7 commits, plain ToT, RL removed).

**Result (2026-09-18):** POSITIVE path PASS — T1 v4 unidir 777 Gb/s (~97% of 800G), v4 bidir
1515 Gb/s, v6 bidir 1504 Gb/s, all with `Local-IP miss drops` = 0 on both nodes. This proves the
per-plane SET_AV learn + the tm_iport=plane<<shift fix (planes 1-3 -> tm_iport 2/4/6) AND the reversed
lip_v6_key are correct on HW (a wrong tm_iport/v6-key would catch-all-drop those planes -> BW collapse).
`nicctl show pipeline internal rdma-local-ip-miss` (opcode 54/TAWK) reads cleanly on HW.
NEGATIVE path (drop+count) NOT exercised on this rig — accepted DOL(SIM v4)+AQ gtest(v4+v6) coverage.
Caveat: positive-only can't distinguish "armed" from "fail-open"; needs a live drop or fw introspection.

**Reusable testbed facts (Meta-RoCE / Hydra multiplane HW):**
- **Meta-RoCE UDP dst port = 2766** (`UDP_PORT_META_ROCE`, meta_roce_defines.h:49), NOT the standard
  RoCEv2 4791. The P4I parser (`p4i/parser.p4` value_set `meta_roce_port`) only sets `cntrl.rdma=1`
  (and thus runs the stage-0 admission check) for dport==2766.
- **After flash + `nicctl reset card`, run `nicctl update multiplane --bdf 0000:c1:00.0`** to reprogram
  the fw per-plane config — the card reset clears it even though the driver sysfs
  `/sys/class/infiniband/rocep195s0f3/mrc_nports` (=4) persists. Without it perftest warns
  "Number of puec planes (4) does not match device configuration (0)".
- That **"device configuration (0)" warning is COSMETIC** — the a-129 perftest reads the old
  `puec_nports` name while the driver exposes `mrc_nports`; `--planes` still works and hits line rate.
- **Cannot test inbound admission from software on a back-to-back RDMA pair:** a host-injected 2766
  (meta-roce) frame is eaten by the SENDER's own TX pipeline (reclassified RDMA, no QP -> drop):
  measured 0 wire arrivals (perf-4 `FRAMES_RX_OK` on eth1/1/3 flat for a 100-pkt scapy burst). A 4791
  frame egresses but the peer treats it as plain Ethernet -> host netdev (tcpdump sees it), no admission.
  perftest `--planes` order-swap does NOT force cross-plane (it normalizes pairing). A true HW negative
  test needs a third-party injector (switch rig) or fw trace/table introspection.
- Multiplane bringup (both nodes): hugepages+governor, `cd /root/gaurav && bash m4setup.sh`
  (assigns 19.N.0.LO + 2001:19:N::N:LO on enp196-199, MTU 9000). RDMA device exposes GIDs on the BASE
  netdev only: idx1=v4 (20.0.0.2), idx2=v6 (2001:20::2); `--planes` carries per-plane addrs, so
  ib_write_bw uses `-x 1` (v4) / `-x 2` (v6) + `--planes=<per-plane IPs>`.
- v6 ND works fine back-to-back (no switch) — v6 cross-plane ping + 1504 Gb/s v6 multiplane both OK.
- Injector tool: `~/lipcheck-hw/inject_roce.py` (staged at `/root/lipcheck/` on perf-3; scapy 2.7.0,
  uses scapy.contrib.roce BTH; default dport 2766). Kept for a future switch-rig negative test.
- Plane MACs: perf-3 enp196-199 = 04:90:81:a7:71:{21,22,23,24}; perf-4 = 04:90:81:a7:6f:{59,5a,5b,5c}.
