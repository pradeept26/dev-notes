# AMD Confidential

# Patent Response — Inventor Q&A

**Invention Title:** ECN-Free RTT Based Adaptive Path Rehashing for Congestion Avoidance in AI NIC Transports

**Responding Inventor:** Pradeep Thangaraju
**Date:** 2026-07-14

---

## Q1. How should the NIC decide what "normal" RTT looks like for a QP?

The NIC maintains a smoothed RTT baseline at the **queue-pair (QP) level** using an exponentially weighted moving average (EWMA) computed from RTT samples observed across all paths of the QP. This QP-level baseline represents the expected RTT for the connection under current network conditions and is continuously updated on each acknowledgment received from the remote endpoint. A separate EWMA is also maintained per path, allowing the NIC to compare each path's observed smoothed RTT against the QP-level baseline to identify paths that are performing worse than the connection average.

---

## Q2. Which RTT measurements should count when deciding what "normal" is?

Only RTT samples from valid acknowledgments contribute. Specifically:

- **Timestamp validity check:** The NIC embeds a transmit timestamp in each outgoing packet. When the acknowledgment returns with an echoed timestamp, the NIC computes the round-trip time. If the computed RTT is implausibly large relative to the current smoothed estimate (for example, more than 64× the current smoothed value), the sample is classified as stale or reordered and discarded without updating any baseline.

- **Retransmitted packets excluded:** RTT samples from retransmitted packets are excluded from baseline updates, since the echo timestamp for a retransmit is ambiguous — the acknowledgment may correspond to the original transmission or the retransmit. This follows established practice (Karn's algorithm) in reliable transport protocols.

- **Active-path samples only:** When a path is deactivated (e.g., due to retransmit timeout or congestion-window exhaustion), no new acknowledgments arrive on it, so it naturally stops contributing samples. On reactivation, a warm-up period before the path's samples re-contribute to the baseline prevents stale RTT state from corrupting the aggregate.

---

## Q3. What information should the NIC remember for each path or entropy value?

The NIC maintains the following per-path state relevant to the RTT-based rehashing mechanism:

- **Smoothed RTT (per-path weighted average):** A continuously updated exponential moving average of the round-trip time observed on this path. This is the per-path measurement that is compared against the QP-level baseline.
- **Entropy value:** The current value of the packet header field used for network-layer ECMP/LAG hashing (e.g., UDP source port). This is the field that is modified when the path is deemed congested to trigger ECMP re-hashing.

At the QP level (across all paths):
- **QP-level smoothed RTT:** The cross-path weighted average baseline described in Q1. Maintained continuously across all active paths of the QP.
- **QP-level minimum RTT:** The lowest RTT sample observed across all paths. Used as an alternative or supplementary baseline in environments where the smoothed average is pulled upward by persistent congestion on one path.

---

## Q4. What condition should make the NIC treat a path as congested?

A path is treated as congested when its smoothed per-path RTT exceeds the QP-level RTT baseline by more than a configurable multiple of the per-path RTT mean deviation:

```
path_congested  =  (per_path_smoothed_rtt  >  qp_baseline_rtt  +  N × per_path_rtt_mean_deviation)
```

Where:
- `per_path_smoothed_rtt` is the EWMA for this path (updated on each ACK from this path).
- `qp_baseline_rtt` is the QP-level EWMA across all paths.
- `per_path_rtt_mean_deviation` is the per-path noise estimate.
- `N` is a configurable multiplier (discussed in Q5).

Using the mean deviation as the unit of the threshold is intentional: the threshold automatically widens in noisy environments (where mean deviation is large) and tightens in stable environments (where mean deviation is small), providing adaptive sensitivity without requiring separate noise-tuning parameters.

Because both values are smoothed averages rather than instantaneous samples, the condition is inherently resistant to transient spikes — sustained deviation across multiple ACKs is required to breach the threshold.

---

## Q5. How should the congestion threshold be set?

The threshold multiplier N (from Q4) is **firmware-configured** at QP setup time and optionally adjustable via a driver-facing administrative interface, consistent with how other per-QP transport parameters (such as minimum window size and maximum window size) are set in the product today.

Recommended default: **N = 4**, which mirrors the coefficient used in standard TCP RTO computation (RTO = smoothed RTT + 4 × mean deviation), providing a threshold that is well-understood, validated in the networking literature, and robust across a range of network RTT profiles.

The EWMA smoothing coefficients (α for the smoothed RTT, β for the mean deviation) are separately configurable per path and default to α = 1/8 and β = 1/4, consistent with the Jacobson/Karels algorithm widely used in reliable transport implementations.

---

## Q6. How should the NIC avoid reacting to temporary RTT spikes?

The primary mechanism for avoiding false positives is the use of smoothed (weighted average) RTT values rather than instantaneous samples for both the per-path measurement and the QP-level baseline:

- **Smoothing on both sides of the comparison:** Both the per-path RTT and the QP-level baseline are weighted moving averages, not instantaneous measurements. A single high RTT sample has limited effect on either value — it takes sustained elevation across multiple ACKs to shift the smoothed per-path RTT far enough above the smoothed baseline to breach the configurable threshold. A transient spike that resolves within a few ACKs will not trigger a rotation.

- **Configurable statistical threshold:** The threshold at which the per-path smoothed RTT is considered to have deviated sufficiently from the QP-level baseline is configurable. Setting it appropriately for the expected RTT variance of the deployment (WAN vs. datacenter) determines the sensitivity of the detector.

- **Stale timestamp guard:** ACKs carrying echo timestamps that are implausibly old relative to the current smoothed RTT estimate are discarded before contributing to RTT measurements, preventing reordered or delayed ACKs from corrupting the baseline.

---

## Q7. After the NIC decides a path is congested, how should it choose where to send traffic next?

The NIC increments the entropy field (e.g., UDP source port) that controls network-layer ECMP/LAG hashing. The increment is randomized (rather than a fixed +1) to reduce the probability that multiple queue pairs that simultaneously rotate will re-converge on the same alternate physical path.

The NIC does not explicitly select a target physical path — it has no visibility into the per-path congestion state of the network fabric. Instead, it relies on the ECMP fabric to distribute the new flow (with its new hash value) across available physical paths. If the fabric has multiple uncongested paths, the new hash is likely to land on one of them. This is the correct design choice: any attempt by the NIC to select a specific target path would require switch telemetry that is not available in standard deployments.

In multiport configurations (where the QP spans multiple NIC ports), the NIC additionally round-robins the entropy rotation across the active port set, distributing probing across all available physical interfaces.

---

## Q8. When should a path that was avoided be used again?

The entropy rotation mechanism does not deactivate the path in the transport sense — it modifies the ECMP hash so that subsequent packets take a different route through the fabric. There is no explicit "path re-enable" step; the path continues operating under the new entropy value.

Recovery is implicit: after rotation, the NIC continues to measure RTT on the (now re-routed) path. If the new route is less congested, the per-path smoothed RTT will decline toward the QP baseline over subsequent ACKs, and the congestion condition will cease to hold. No timer or explicit recovery signal is needed.

If RTT does not improve after rotation (e.g., the new ECMP route is equally congested), the cooldown period expires and the NIC may rotate again, subject to the K-consecutive-sample gate. The rotation count per path is bounded to prevent indefinite probing.

---

## Q9. How often is the NIC allowed to change the path for traffic?

The original disclosure specifies that entropy is changed when the congestion condition is detected — path RTT deviates beyond the configurable threshold relative to the QP-level baseline. The rate of rotation is therefore governed by the rate at which the smoothed per-path RTT breaches the threshold, which is naturally bounded by the EWMA smoothing: sustained elevation across multiple ACKs is required to move the smoothed value far enough to trigger detection.

Rotation is not gated on message or operation boundaries. Since the Meta RoCE transport is designed to tolerate out-of-order delivery across paths, entropy change at any ACK-event boundary does not cause correctness issues.

---

## Q10. Are there any special interactions with other transport behavior?

| Transport behavior | Interaction |
|---|---|
| **Retransmission (RTO / SACK)** | RTT samples from retransmitted packets are excluded from both the per-path smoothed RTT and the QP-level baseline (Karn's algorithm). This prevents a loss event, which transiently inflates measured RTT, from triggering a spurious entropy rotation. |
| **ECN / CNP feedback** | Patent-1 is designed for environments where ECN marks are absent or unreliable (WAN, ECN-disabled fabrics). When ECN/CNP is present, the existing congestion-control pipeline reduces the sender window — the RTT-deviation trigger complements this by acting on the path dimension when the rate-reduction response alone is insufficient. The two mechanisms are compatible and non-conflicting. |
| **FEC retries and link errors** | FEC-induced retransmissions add a fixed latency increment on degraded links. This shows up as a sustained RTT elevation (not a transient spike), which is exactly the condition Patent-1 is designed to detect. The EWMA smoothing and K-consecutive-sample requirement correctly distinguish this from transient noise. |
| **Receiver-not-ready (RNR) backoff** | During RNR backoff intervals, no new packets are sent and no new ACKs arrive on the affected path. RTT sampling is naturally suspended. RTT state resumes updating when the backoff expires and transmission resumes. The path should not be classified as congested during an RNR interval. |
| **Delayed acknowledgments** | Receiver-side ACK delay adds a fixed increment to all RTT measurements equally across all paths. Since Patent-1 operates on the *relative deviation* of per-path RTT from the QP-level baseline (not on absolute RTT values), uniform ACK delay does not affect the detection logic — it shifts baseline and per-path RTT by the same amount. |
| **Path deactivation / reactivation** | When a path is deactivated (e.g., by congestion-window exhaustion or retransmit timeout), its per-path RTT stops updating. On reactivation, a warm-up period (configurable, e.g., 4 ACKs) should pass before the path's RTT re-contributes to the baseline and before the path becomes eligible for RTT-deviation-triggered rotation. |

---

## Q11. Where is this logic implemented in the product?

All components of the mechanism run inside the NIC, with no involvement from the host driver, host software, or any network device.

| Function | Location |
|---|---|
| RTT measurement from echoed timestamp | NIC receive-side pipeline (triggered on each incoming acknowledgment packet) |
| Per-path smoothed RTT and mean deviation update | NIC receive-side pipeline, later processing stage |
| QP-level baseline RTT update | NIC receive-side pipeline, earlier processing stage (runs on each ACK regardless of path) |
| Congestion detection (deviation comparison, K-sample counter) | NIC receive-side pipeline — both the per-path RTT and the QP-level baseline are accessible at this point |
| Cross-pipeline signal (rotation request from RX to TX pipeline) | Single-bit flag carried in the per-packet metadata vector from the receive pipeline to the transmit scheduler; same mechanism used by other RX-to-TX signaling in the existing firmware |
| Entropy field rotation | NIC transmit-side pipeline — increments the per-path entropy state; subsequent packets carry the new value in the relevant header field |
| Cooldown tracking and rotation-count limiting | Per-path control state in NIC-local memory, updated by the transmit pipeline on each rotation event |
| Parameter configuration (N, K, cooldown, α, β) | Written to NIC control state at QP setup time via the existing administrative command interface; no new hardware or memory regions required |

No protocol changes are required. No receiver-side coordination is needed. The mechanism is invisible to the remote endpoint and to the network infrastructure.

---

*End of inventor response.*
