# AMD Confidential — Patent Family Handoff Document

**Subject:** Meta RoCE / Pollara AINIC — Multipath RDMA Transport Patent Family
**Prepared by:** Pradeep Thangaraju
**Date:** 2026-06-30
**Status:** Working draft — for internal review and patent counsel engagement

---

## 1. Executive Summary

This document captures three related invention disclosures (IDFs) arising from the AMD Pollara AINIC Meta RoCE multipath RDMA transport design. The three inventions are complementary and non-overlapping: they address different layers of the same problem space (congestion detection, CC-floor-constrained path migration, and pipeline efficiency under window exhaustion). Together they form a coherent patent family.

| # | Title (short) | File | Status | Lead Inventor | Estimated strength |
|---|---|---|---|---|---|
| P1 | RTT-based Adaptive Path Rehashing | `~/Patent-1.pdf` | IDF submitted | Vishwas Danivas | ~50-55% |
| P2 | CC-Floor-Triggered Path Rehashing | `~/Patent-2-IDF.md` | Draft | Pradeep Thangaraju | ~65-70% |
| P3 | Pipelined Continue-and-Stage | `~/Patent-3-IDF.md` | Draft | Pradeep Thangaraju | ~55-65% |

**Target product:** Pollara AINIC (current); applicable to successor AINIC families.
**Patent committee:** Networking and Interconnect Patent Committee.

---

## 2. Technical Background

### 2.1 Product Context

The inventions arise from the **Meta RoCE** transport — a custom multipath RoCEv2-class RDMA transport implemented in AMD AI NIC firmware (Vulcano/Hydra platforms, branded Pollara AINIC). The transport runs in a multi-stage P4+ hardware pipeline (stages S0–S7) with per-path congestion control, multipath scheduling, and hardware-offloaded retransmission.

Key architectural properties relevant to the patents:

- **Multipath per QP:** Each queue pair (QP) is assigned multiple network paths. Each path has its own congestion window, sequence number space, and entropy field (UDP source port) controlling ECMP hashing.
- **Per-path doorbell rings:** Five doorbell rings per path (ACK/NAK, RETX-RTO, RETX-SACK, timer, CWND-retry). The CWND-retry ring is a doorbell-only signal; it has no payload memory.
- **Retransmit ring:** Each path has a dedicated HBM-backed ring buffer (NIC-local storage) that holds committed per-packet state for retransmission and for staged replay.
- **CC algorithms:** DCQCN/AIMD-class; minimum-window floor (`qwnd_min`) enforced to prevent total flow starvation.
- **Pipelined execution:** PHVs (packet header vectors) flow through the pipeline and may reach the window-check stage while the window is already closed (race between parallel dispatches).

### 2.2 Problem Space

Three distinct but related problems in multipath RDMA at AI-workload scale:

1. **Path quality sensing without ECN** (→ Patent-1): How does a NIC detect that a specific physical path is congested when ECN marks may be absent (WAN, ECN-disabled networks)?

2. **CC effectiveness at high QP fan-out** (→ Patent-2): With 400+ QPs per host, per-QP fair share falls below the CC minimum-window floor. The CC's affirmative response (rate reduction) is silently discarded. How does the system respond?

3. **Pipeline efficiency under window exhaustion** (→ Patent-3): When the per-path congestion window is exhausted while packets are already in-flight through the egress pipeline, how does the NIC handle those packets without stalling the pipeline or discarding work?

---

## 3. Patent-1 — ECN-Free RTT-based Adaptive Path Rehashing

### 3.1 Summary

**Full title:** "ECN-Free RTT based Adaptive Path Rehashing for Congestion Avoidance in AI NIC Transports"
**IDF file:** `~/Patent-1.pdf` (4 pages)
**Status:** IDF submitted to AMD patent committee. Not yet filed.

**Inventors:**
- Vishwas Danivas (main) — vishwas.danivas@amd.com — US, CA, Santa Clara
- Pradeep Thangaraju — pradeep.thangaraju@amd.com — IN, Bangalore
- Balakrishnan Raman — balakrishnan.raman@amd.com — US, CA, Santa Clara

### 3.2 Core Mechanism

The NIC measures RTT on a per-path basis. It maintains a smoothed RTT baseline at the QP level (across all paths of the QP). When a specific path's RTT exceeds the QP-level baseline by a configurable threshold, the NIC rotates the UDP source port (or equivalent ECMP-influencing header field) to force ECMP re-hashing of subsequent packets onto a different physical path.

- **Trigger:** Per-path RTT statistical deviation from per-QP RTT baseline
- **Response:** Entropy rotation (UDP sport increment) → ECMP re-hash → different physical path
- **Execution:** NIC-local; no control-plane involvement; no receiver coordination

### 3.3 Relationship to Existing Code

Entropy-rotation infrastructure already exists in AMD AI NIC firmware:
- Rotation fires on RTO (retransmit timeout) and on new-path bootstrap
- Patent-1 adds a new trigger: RTT-threshold deviation
- The sensing (per-path RTT vs. QP-level baseline) is the genuinely new mechanism

### 3.4 Known Weaknesses (identified during review)

The submitted IDF has several gaps that should be addressed before formal filing:

1. **"Existing Known Solutions: not aware" is factually wrong.** Prior art that must be enumerated:
   - TIMELY (Mittal et al., SIGCOMM 2015) — RTT-gradient CC without ECN
   - Swift (Kumar et al., SIGCOMM 2020) — RTT-based CC with fabric RTT decomposition
   - HPCC (Li et al., SIGCOMM 2019) — INT-based fine-grained CC
   - Hermes (Zhang et al., NSDI 2019) — cautious path-quality-aware LB
   - LetFlow (Vanini et al., NSDI 2017) — flowlet switching on idle gaps
   - CONGA (Alizadeh et al., SIGCOMM 2014) — switch-side flowlet LB
   - HULA (SOSR 2016), MPRDMA (Lu et al., NSDI 2018)
   - The IDF must enumerate these and articulate what Patent-1 adds over each.

2. **Statistical method is vague.** "Configurable thresholds" needs to be specified: EWMA + N×σ? Percentile-based? The claim language must be specific enough to be defensible.

3. **No oscillation/flapping mitigation.** Hermes (prior art) uses "cautious switching" to prevent thrash. Patent-1 doesn't address flapping between paths when RTTs are noisy.

4. **No RTT-jitter robustness.** FEC retries, link errors, and brief bursts can spike RTT without actual congestion. The IDF doesn't describe how to distinguish congestion-induced RTT from noise-induced RTT.

5. **Design Arounds section is empty.** Must be filled before patent committee.

6. **Doesn't clarify implementation status.** Is this implemented in Pollara firmware today, or speculative?

### 3.5 Strongest Defensible Angle

The *combination* of:
- Per-path RTT statistical deviation from QP-level baseline (not absolute RTT thresholds)
- Entropy rotation as the response (not rate reduction or flow pausing)
- NIC-resident execution (no control-plane, no receiver)
- Tuned for WAN/ISP RTT regimes where ECN is unavailable

Individual pieces have prior art; the combination + WAN-tuning is the differentiator.

### 3.6 Next Steps

- [ ] Engage AMD patent counsel to review the submitted IDF
- [ ] Enumerate prior art and articulate delta (see §3.4 item 1)
- [ ] Specify the statistical method (EWMA parameters, threshold formula)
- [ ] Add oscillation mitigation and RTT-jitter robustness description
- [ ] Fill Design Arounds section
- [ ] Clarify implementation status in IDF

---

## 4. Patent-2 — CC-Floor-Triggered Adaptive Path Rehashing

### 4.1 Summary

**Full title:** "Congestion-Control Floor-Triggered Adaptive Path Rehashing in High-QP-Scale Multipath AI NIC Transports"
**IDF file:** `~/Patent-2-IDF.md`
**Status:** Draft (pre-submission). Ready for inventor review.

**Inventors:**
- Pradeep Thangaraju (main) — pradeep.thangaraju@amd.com — IN, Bangalore
- Vishwas Danivas — vishwas.danivas@amd.com — US, CA, Santa Clara
- Balakrishnan Raman — balakrishnan.raman@amd.com — US, CA, Santa Clara

### 4.2 The Problem

At high QP fan-out (400+ QPs per host in large AI training collective communication operations), the per-QP fair share of available link capacity falls below the CC minimum-window floor (`qwnd_min`). When a congestion signal (ECN/CNP mark) arrives, the CC pipeline computes a proposed multiplicative decrease. If the result would fall below `qwnd_min`, the operation is silently discarded — the signal is acknowledged and thrown away. The QP continues sending at floor rate on the same congested physical path.

This creates a positive feedback loop: the QP can't slow down (floor enforced), it can't escape the path (no mechanism), so it perpetuates the congestion that triggered the signal.

### 4.3 Core Mechanism

At each CC pipeline MD (multiplicative decrease) floor check, instead of returning silently when the floor is hit:

1. **Detect:** Record that a decrement-suppressed event occurred for this path
2. **Signal:** Notify the TX scheduler that the affected path needs a path-level response
3. **Respond:** TX scheduler rotates the per-path entropy field (UDP sport or equivalent ECMP hash input) for subsequent packets → ECMP re-hash → different physical path
4. **Converge:** Rate-limit rotations to at most one per N RTTs; require K consecutive suppressed events within window W before firing (false-positive smoothing); randomize entropy delta (avoid synchronized re-convergence)

The result: when rate reduction is impossible (floor enforced), the QP instead **moves** to a less-congested path.

### 4.4 Why It's Novel

The trigger — *multiplicative decrease suppressed by minimum-window floor* — is a single, well-defined, observable event that no known prior art uses as a path-level redistribution trigger:

| Prior art | Trigger for path action | Gap |
|---|---|---|
| DCQCN | Defines floor; no compensating action at floor | No path-level response |
| TIMELY | Defines minimum rate; no path action | No path-level response |
| Hermes | Path quality observation (external signal) | Different trigger |
| LetFlow | Inter-packet idle gap | Different trigger |
| Patent-1 (sister) | Per-path RTT deviation from baseline | Different trigger; different regime (WAN/ECN-absent) |

The combination of (floor-suppression event as trigger) + (entropy rotation as response) + (NIC-local, no protocol change) is novel.

### 4.5 Relationship to Patent-1

Same response mechanism (entropy rotation), different trigger and different target regime:

| | Patent-1 | Patent-2 |
|---|---|---|
| Trigger | RTT deviation from QP baseline | CC floor suppression |
| Target regime | WAN / ECN-unavailable | High QP fan-out datacenter |
| Sensing location | RX pipeline (RTT measurement) | RX CC pipeline (MD floor check) |
| Filed separately? | Yes — keep claim language tight |

### 4.6 How to Detect (Infringement)

**Pcap signature:**
- Congestion-marked (ECN/CNP) packets arriving at sender NIC
- Sender per-QP rate steady at configured minimum-window floor (no throttling response visible)
- UDP source port values changing on subsequent packets from same QP within a few RTTs of congestion-mark arrival
- Per-QP physical-path assignment changing in correlation with the port field changes

**Black-box NIC test:** Configure NIC at minimum window floor; inject ECN/CNP marks; verify UDP sport rotation in transmitted packets.

### 4.7 Next Steps

- [ ] Vishwas and Balakrishnan review `~/Patent-2-IDF.md` and confirm co-inventorship
- [ ] Prior-art scan before submission:
  - Falcon (Google, 2024) — receiver-driven scheduling; check if floor-saturation regime is addressed
  - Swift (2020) — RTT-based CC; verify floor behavior at high fan-out
  - DCQCN (2015) — check whether any extension addresses floor saturation
  - Internal Pensando/AMD patent family search (via counsel)
- [ ] Empirical validation on SMC testbed:
  - Drive 400+ QPs from one host; confirm CC floor collapse at baseline
  - Implement trigger; measure aggregate throughput and p99 latency vs. baseline
- [ ] Engage AMD patent counsel for pre-submission review
- [ ] Decide: file jointly with Patent-1 (common response mechanism) or separately (cleaner claim language)?

---

## 5. Patent-3 — Pipelined Continue-and-Stage with Deferred Wire Egress

### 5.1 Summary

**Full title:** "Pipelined Work Staging with Deferred Wire Egress and Doorbell-Driven Replay for Congestion-Window Enforcement in AI NIC RDMA Transports"
**IDF file:** `~/Patent-3-IDF.md`
**Status:** Draft (pre-submission). Inventors to be confirmed.

**Inventors (tentative):**
- Pradeep Thangaraju (main) — pradeep.thangaraju@amd.com — IN, Bangalore
- Vishwas Danivas — vishwas.danivas@amd.com — US, CA, Santa Clara
- Balakrishnan Raman — balakrishnan.raman@amd.com — US, CA, Santa Clara

### 5.2 The Problem

When the per-path congestion window is exhausted, packets may already be in-flight through the NIC's egress pipeline. Two conventional approaches:

| Approach | Mechanism | Cost |
|---|---|---|
| **Stall** | Stop dispatching from SQ; pipeline idles | Wasted pipeline cycles; all paths delayed |
| **Drop + retransmit** | Discard in-flight packet; RTO/NACK triggers re-fetch | PCIe DMA re-fetch cost; recovery latency tied to timer not window-open |

Both are suboptimal at the throughput rates and QP fan-outs required for large AI training workloads.

### 5.3 Core Mechanism

**The key insight:** By the time a packet reaches the window-check stage, the expensive work (WQE fetch, parse, sequence-number planning) is already done. Throwing that work away (drop) or never starting it (stall) wastes it.

Instead: **continue the packet through the full pipeline; commit all per-packet state; suppress only the final wire transmission**.

#### Dual-Frontier Sequence Management

The NIC maintains two per-path sequence counters:

```
tx_frontier   (= snd_nxt)  — next FSN for wire-eligible packets; FROZEN at window exhaustion
stage_frontier (= snd_max)  — next FSN for any packet (including staged); KEEPS ADVANCING
```

The gap `[tx_frontier .. stage_frontier)` = packets committed to the retx ring but not yet transmitted on the wire.

#### Per-Packet Pipeline Behavior

```
For every packet entering egress pipeline:
  1. Allocate FSN:
       window open   → from tx_frontier  (tx_frontier++)
       window closed → from stage_frontier (stage_frontier++)
  2. Write committed per-packet state → retx ring  [UNCONDITIONAL]
  3. Check window:
       window open   → insert wire headers; transmit on wire
       window closed → suppress wire headers; arm replay doorbell
  4. Pipeline continues — NO STALL in either case
```

#### Doorbell-Driven Replay

When the window reopens (ACKs advance the outstanding-packet count):

```
Replay doorbell fires:
  while tx_frontier < stage_frontier:
    entry = read retx_ring[tx_frontier]
    transmit on wire                    ← no host DMA; no pipeline re-execution
    tx_frontier++
  clear replay doorbell
```

### 5.4 Why It's Novel

All known prior art handles window exhaustion by either:
- **Stalling** at the SQ dispatch stage before the pipeline is invoked (traditional InfiniBand HCA, RoCEv2 implementations, hardware pacers)
- **Dropping** the in-flight packet and recovering via retransmit timer (drop-and-RTO model)

No known prior art:
- Continues the packet through the full pipeline on window exhaustion
- Commits per-packet state (FSN + retx-ring entry) unconditionally
- Defers **only** the wire-egress step
- Replays from on-NIC committed state (no host re-fetch)

The "commit-and-defer-wire" primitive — separating work commitment from wire transmission — is the novel architectural concept.

### 5.5 Dependent Claims

**Claim A — TX/RX path-bitmap parity handshake:**
When a path is removed from the active scheduler bitmap due to window exhaustion, the TX pipeline flips a 1-bit parity indicator per path. The RX pipeline records the observed parity when processing received packets on that path. RX confirms path removal only when its observed parity matches the TX-side bit — guaranteeing all in-pipeline TX packets for the removed path have been fully processed before path state is modified. This prevents a class of races unique to multipath pipelined NICs where TX and RX share path control state.

**Claim B — Re-activation gate:**
A path is not re-admitted to normal new-work dispatch until:
- `tx_frontier == stage_frontier` (all staged entries replayed — no staged work outstanding)
- No cross-pipeline force-deactivation signal is present (e.g., port-failover notification from TX to RX)
- Outstanding wire-transmitted packets ≤ threshold relative to window (hysteresis)

Without condition (i), new WQEs could receive FSNs that interleave with the staged range, violating ordering.

**Claim C — Entropy rotation on replay (composability with Patent-2):**
When the replay doorbell fires and the path is re-activated, optionally rotate the per-path entropy field (UDP sport). Replayed packets re-enter the network on a potentially different physical path. This composes Patent-3 (staging substrate) with Patent-2's entropy-rotation response, using "window just reopened after staged drain" as the rotation trigger.

### 5.6 Retransmit Ring Sizing

The retx ring must hold both:
- **Normal in-flight packets:** bounded by pipeline depth × max concurrent pipeline contexts
- **Staged-but-not-transmitted packets:** bounded by max window size (outstanding-packet limit)

In exact cwnd-enforce mode (where no window overshoot is tolerated), the ring must hold both simultaneously. Per-path ring size:

| Mode | Slots | Per-path size |
|---|---|---|
| Simulator | 64 | 4 KB |
| HW allow-overshoot | 256 | 16 KB |
| HW exact-enforce | 512 | 32 KB |

HBM-first allocation; can spill to host memory if HBM pool exhausted (fatal in practice — ring overflow is a hard error).

### 5.7 Interaction with Retransmit-Timer Recovery

The same retx ring serves both staged-replay and timer-triggered retransmission. The two ranges are distinct:
- `[snd_una .. tx_frontier)` — wire-transmitted, awaiting ACK → eligible for RTO recovery
- `[tx_frontier .. stage_frontier)` — staged, not yet transmitted → eligible for replay-doorbell drain only

A retransmit-timer event must not replay staged entries before the window reopens (that would violate cwnd enforcement). The firmware distinguishes ranges by comparing per-packet FSN against the frozen `tx_frontier`.

### 5.8 How to Detect (Infringement)

**Pcap + host-side measurement:**
1. Sustain traffic with ACK-delay shaper creating window exhaustion on one path
2. During exhaustion:
   - PCIe DMA reads from host (WQE re-fetches): **absent** (staged replay reads from NIC ring, not host)
   - Pipeline-idle NIC telemetry counters: **absent** (pipeline continues executing)
   - Wire traffic on exhausted path: **absent** (wire suppressed)
3. When ACK-delay shaper releases and window reopens:
   - Burst of packets on previously-absent UDP source port
   - **No preceding PCIe DMA burst to host** (distinguishes staged-replay from drop+RTO)
   - Packets form contiguous FSN range starting at last-ACKed FSN (consistent with staged-replay ordering)

### 5.9 Next Steps

- [ ] Confirm inventors with Vishwas and Balakrishnan — determine who contributed to the pipelined-continue design specifically
- [ ] Prior-art scan:
  - Nvidia/Mellanox BlueField HCA retransmit-buffer architecture (any staged-commit pattern in pipeline?)
  - iWARP FPGA offload literature (circa 2016-2022)
  - Recent SmartNIC/P4-NIC research (any commit-and-defer pattern?)
  - Internal Pensando/AMD patent family search (via counsel)
- [ ] Engage AMD patent counsel before any external disclosure
- [ ] Empirical validation:
  - On SMC testbed: measure pipeline utilization (NIC counters) and PCIe DMA traffic during window exhaustion
  - Compare staged-replay burst timing vs. RTO recovery timing
- [ ] Decide: file Patent-3 independent of, or as a continuation of, Patent-2?

---

## 6. Relationship Map

```
                        ┌─────────────────────────────────────────┐
                        │         POLLARA AINIC META ROCE          │
                        │    Multipath RDMA Patent Family          │
                        └─────────────────────────────────────────┘

  WHEN TO CHANGE PATH                        HOW PIPELINE HANDLES CLOSED WINDOW
  ─────────────────────                      ──────────────────────────────────

  Patent-1                Patent-2                Patent-3
  ───────────────         ────────────────         ──────────────────────────────
  RTT deviation           CC floor blocked         Window exhausted
  from QP baseline   →    → silently               → in-flight PHVs staged
  → entropy rotate        discarded               → committed to retx ring
                          → entropy rotate         → wire suppressed
  Trigger: sensing        (this invention)         → replay via doorbell
  Response: steering      Trigger: floor event
                          Response: steering       Trigger: window enforcement
  Target: WAN / no-ECN                            Response: pipeline efficiency
                          Target: high QP fanout
  Status: IDF submitted                           Status: IDF draft
                          Status: IDF draft
  P1 ──────────────────────────────────────────── P3
  (same response         P2 composes with P3:      (substrate on which P1+P2
   mechanism,            entropy rotate can          path transitions execute
   different trigger)    fire on P3 replay           safely and cleanly)
```

**Key non-overlap statement:**
- P1 and P2 share the response mechanism (entropy rotation) but have distinct, non-overlapping triggers and target regimes. Filed separately to keep claim language tight.
- P3 is orthogonal to both P1 and P2 — it addresses pipeline behavior, not path selection. It is the substrate that makes P1 and P2 path transitions clean (Claim C of P3 is the explicit composability hook).

---

## 7. Code References (Internal — Do Not Include in IDF Submissions)

The following are internal code pointers for inventor verification and prior-art-search context. This section is for AMD internal use only and must not appear in any IDF submitted to outside counsel.

| Concept | Source location |
|---|---|
| CWND-retry doorbell ring (ring ID 4) | `include/meta_roce_defines.h` |
| TX window check + staged FSN allocation | `meta_roce/tx_s3.p4` — `req_tx_path_context_process` action |
| Retx ring write (`_retx_wqe_dma_cmd_add`) | `meta_roce/tx_s3.p4` |
| Wire suppression (`pred.add_headers = 0`) | `meta_roce/tx_s3.p4` |
| Replay doorbell arm (`retry_ring_db = 1`) | `meta_roce/tx_s7.p4` |
| TX/RX path parity bits (`path_removed_tx/rx`) | `include/path_cb.p4` — `path_cb2` struct |
| RX re-activation gate | `meta_roce/rx_s3.p4` — path bitmap update logic |
| CC floor check (MD suppression site) | `meta_roce/rx_s2.p4` — `_multiplicative_decrease` macro |
| Entropy rotation (`entropy_sport++`) | `meta_roce/tx_s3.p4` — RTO and bootstrap sites |
| Retx ring HBM region | `nic/conf/gen/a35_mem_reg.json` — `meta_roce_retx` |
| Retx memory pool init + sizing | `nicmgr/plugin/rdma/init.c` — `g_meta_roce_retx_mem_pool` |
| Five bitmaps (SQCB1) | `include/path_cb.p4` — SQCB1 struct |

**Documentation artifacts** (in sw-2 repo, private):
- `nic/rudra/src/hydra/p4/p4plus-16/meta_roce/docs/02-tx-pipeline.md` — §3.0 Ring Memory Layout, §5.7 Path Lifecycle with CC
- `nic/rudra/src/hydra/p4/p4plus-16/meta_roce/docs/03-rx-pipeline.md` — §3.6 Path Bitmap Management
- `nic/rudra/src/hydra/p4/p4plus-16/meta_roce/docs/06-debugging.md` — CWND Retry Stuck, Path Flapping sections

These documentation artifacts establish invention disclosure date and author.

---

## 8. Open Decisions

| # | Decision | Options | Owner |
|---|---|---|---|
| D1 | P1: Prior-art treatment before filing | Counsel adds enumerated prior art + delta | Vishwas + counsel |
| D2 | P2: File jointly with P1 or separately? | Jointly (shared response mechanism) vs. separately (cleaner claims) | Pradeep + counsel |
| D3 | P3: File independently or as continuation of P2? | Independent (orthogonal mechanism) vs. continuation (cost savings) | Pradeep + counsel |
| D4 | P3: Confirm inventor list | Who specifically contributed to the pipelined-continue design? | Pradeep |
| D5 | P2+P3: Empirical validation timeline | SMC testbed validation at 400+ QP scale | Pradeep |
| D6 | All: Internal pre-disclosure review | Must complete before any Confluence page, conference talk, or paper | All inventors |

---

## 9. Pending Actions Before Submission

### Immediate (before engaging counsel)

- [ ] Confirm all inventor lists for P2 and P3
- [ ] Vishwas and Balakrishnan review and acknowledge `~/Patent-2-IDF.md` and `~/Patent-3-IDF.md`
- [ ] Internal pre-disclosure review — ensure nothing in the IDF files reveals implementation details that are also in any public PR, Confluence page, or conference submission

### Before formal IDF submission

- [ ] Prior-art scan for P2 (CC floor + path rotation): Falcon 2024, Swift 2020, DCQCN extensions
- [ ] Prior-art scan for P3 (pipelined commit-and-defer): Mellanox HCA retransmit architecture, iWARP FPGA offload
- [ ] Enumerate prior art and delta in P1 IDF (currently "not aware" which is factually wrong)
- [ ] Empirical validation plan for P2 (SMC testbed, 400+ QPs)
- [ ] Empirical validation plan for P3 (PCIe DMA measurement during window exhaustion)

### Patent counsel engagement

- [ ] Pull internal Pensando/AMD patent family search to confirm no self-conflict
- [ ] Submit P2 IDF and P3 IDF to Networking and Interconnect Patent Committee
- [ ] Resolve D2 and D3 (filing strategy) with counsel guidance
- [ ] Address P1 IDF weaknesses (D1) in coordination with Vishwas and counsel

---

## 10. Confidentiality Note

All three inventions are **AMD Confidential**. The IDF files (`Patent-1.pdf`, `Patent-2-IDF.md`, `Patent-3-IDF.md`) and this handoff document must not be:
- Shared outside AMD without legal review
- Posted to any public code repository, Confluence space with external access, or conference submission system
- Discussed in detail in public Slack channels or external communication

The invention disclosure date is established by the file creation date in this private repository and by the internal Slack messages exchanged during the invention development.

---

*End of document.*
