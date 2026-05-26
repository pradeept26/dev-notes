# Meta-RoCE Protocol Overview

**Specification:** Meta-RoCE Protocol for AI Accelerators v0.97 (Draft)
**Date:** April 6, 2026
**Classification:** Meta Proprietary and Confidential. Shared with AMD under NDA.

---

## 1. What Meta-RoCE Is

Meta-RoCE is an **RDMA transport protocol** designed for hardware-offloaded operation over best-effort Ethernet networks with shallow-buffer switches. It targets large-scale AI training clusters where thousands of accelerators exchange data across networks spanning racks, buildings, and geographic locations. The protocol is designed to scale to hundreds of thousands of nodes and millions of network endpoints without compromising tail latency.

Meta-RoCE multiplexes connection management, multipath load balancing, congestion control, and stream multiplexing into a single reliable connection managed by the NIC transport layer.

---

## 2. Design Goals and Motivations

### 2.1 Problems with Traditional RDMA Transports

**Priority Flow Control (PFC) does not scale:**
- Switch buffer reserved for PFC headroom grows with link speed and distance, consuming memory that could absorb transient bursts.
- A single congested port propagates pause frames upstream, stalling unrelated traffic (pause storms).
- PFC operates per traffic class rather than per flow; a misbehaving or slow receiver can block all senders sharing that class.

**Single-path connections compound issues:**
- ECMP hashes each connection to one network path; when multiple connections hash to the same link, that link becomes a bottleneck while parallel links sit idle.
- Hash collisions are unavoidable in large fabrics and worsen as the number of endpoints grows.
- Spreading a single large transfer across multiple paths requires either switch-level packet spraying with reorder buffers, or endpoint-directed multipath.

**QP scaling is expensive:**
- Creating many parallel connections between the same pair of endpoints (QP scaling) multiplies per-connection state on NIC memory that is constrained by power and area.
- Congestion control fragments across many small windows.
- Modern training workloads generate dozens of concurrent communication streams between the same endpoint pair, multiplying QP scaling costs.

### 2.2 Meta-RoCE Design Goals

| Goal | Description |
|------|-------------|
| High network efficiency | Sustaining throughput without head-of-line blocking |
| Resilience | Recovering from packet loss and partial failures without visible impact on application performance |
| Adaptability | Evolving workloads, link speeds, and network topologies; programmable congestion control parameters tunable without hardware changes |
| Practical implementation | On-chip alongside special-purpose accelerators, where power and area constrain NIC memory and logic resources |

### 2.3 What Meta-RoCE Addresses

Meta-RoCE addresses PFC limitations by:
- Combining **multipath load balancing**, **congestion control**, and **stream multiplexing** into a single reliable connection managed by the NIC transport layer.
- **Treating the network as lossy** and recovering from packet loss through selective acknowledgment and retransmission, eliminating the need for PFC on data traffic.
- Using **per-path windows** so a path that stops acknowledging can be declared failed and its traffic moved to surviving paths, whereas oblivious packet spraying cannot distinguish a failed path from transient congestion.

---

## 3. How Meta-RoCE Differs from Standard RoCEv2

### 3.1 What Is Removed / Not Required

| RoCEv2 Feature | Meta-RoCE Status |
|----------------|-----------------|
| PFC (Priority Flow Control) | **Not required.** Meta-RoCE treats the network as lossy and recovers from packet loss through selective ACK and retransmission. |
| Switch-level packet spraying | **Not required.** The NIC manages its own multipath load balancing by directing packets across paths with different entropy values. |
| Packet trimming | **Not used.** Meta-RoCE does not rely on switch-level packet trimming. |
| In-network telemetry | **Not used.** Meta-RoCE relies on end-to-end measurements and ECN signals only. |
| Credit-based flow control | **Not required.** Meta-RoCE uses receiver-driven rate limiting at the transport layer instead of link-level credits. |
| QP-level Packet Sequence Number (PSN) | **Replaced.** There is no QP-level PSN. Packets within messages are not identified as first/middle/last (as in RoCEv2). Instead, the Flow Sequence Number (FSN) is used per path. |
| iCRC (Invariant CRC) | **Replaced** by mCRC (Meta-RoCE CRC). The mCRC covers only Meta-RoCE headers and data, not LRH/GRH of a RoCEv2 iCRC. |
| Single-path per connection | **Replaced.** Meta-RoCE maintains multiple Paths within a connection, each with its own sliding window and selective acknowledgment state. |
| Single completion ordering per QP | **Extended.** Meta-RoCE adds Tags — independent sub-queues within a QP — each with its own MSN/CSN space and completion ordering. |

### 3.2 What Is Added / Extended

| Feature | Description |
|---------|-------------|
| Tags | A single Meta-RoCE connection (QP) can carry multiple independent message streams called Tags. Each Tag has its own sequence number space and completion ordering. |
| Explicit Multipath Transport | The sender maintains multiple Paths within a connection, each with its own sliding window and selective ACK. Entropy value in each packet's encapsulation header directs traffic across different ECMP routes. |
| Relaxed-order data delivery | Data packets can arrive and be written to memory out of order; completions are delivered to the application in order. No large on-NIC reorder buffers required. |
| Flow Sequence Number (FSN) | Per-path packet sequence number. The unit of acknowledgment and retransmission. An FSN is immutably bound one-to-one to a (Tag, Opcode, MSN, POSN) tuple. |
| Message Sequence Number (MSN) | Per QP+Tag unique message identifier. Scoped within the QP+Tag (not the whole QP). |
| Packet Offset Sequence Number (POSN) | Sequence number within a message. Starts at zero in every message. 16-bit field. Cannot wrap. Maximum message = 2^28 bytes (256 MB). |
| Completion Sequence Number (CSN) | Tracks in-order completion of Receive-WQE-consuming operations at the responder. Scoped per QP+Tag. |
| CDMSN | Cumulative-Responder-Delivered-MSN. The highest MSN of in-order received and delivered messages. Carried in ACKs. |
| Receiver Driven Rate Limiting (RCN) | Receiver signals a TargetRate in every ACK representing a fair-share bitrate; sender sets QWND_max to converge to this rate. |
| Hierarchical congestion windows | QP-level window (QWND) decomposes into per-path windows (PWND[p]). QWND limits outstanding packets on entire QP; PWND[p] balance traffic across paths. |
| Fast Start | Window increments on transmission rather than on ACK at the beginning of an operation, probing bandwidth quickly. |
| Alternate Path Retransmission | On RTO, the sender may change the entropy value (UDP source port) to attempt a different physical path. |
| Eager Tail Retransmission | An optimization to retransmit the last packet early when tail loss is suspected. |
| BRNR / HRNR distinction | Two distinct RNR mechanisms: BRNR (Buffer RNR — receive WQE missing, state present in cache) vs HRNR (Hardware RNR — QP not initialized or not cached). |
| RNR-Cancel packet | A new packet type sent when the receiver becomes ready after an RNR condition. |
| Multi-port support | A QP's paths may be associated with different physical interface ports. The NIC determines which physical port each packet is sent on. |
| In-protocol Ping (Echo) | A control packet for firmware-to-firmware connectivity probing and path/QP state interrogation. |
| Programmable (Advanced) CC | Optional software-defined congestion control algorithm using signals exposed by the hardware. |

### 3.3 Opcode Transport Type Field

Meta-RoCE uses the value `110` in bits [7:5] of the RoCEv2 opcode to indicate the transport type. This is one of two values reserved for manufacturer-defined opcodes. Bits [4:0] specify individual opcodes and follow the general pattern defined in RoCEv2 (where RoCEv2 defines "first", "middle", and "last" codes, Meta-RoCE adopts the "first" opcode and leaves the remaining two reserved).

### 3.4 UDP Destination Port

Meta-RoCE uses UDP destination port **2766**.

### 3.5 mCRC vs iCRC

- **iCRC (RoCEv2):** Covers LRH/GRH and IB transport headers and payload.
- **mCRC (Meta-RoCE):** CRC-32, pre-inverted (starts with -1) and post-inverted, using the same polynomial as the Ethernet CRC. Starts from the beginning of the Meta-RoCE header and extends to the end of the data. Does **not** include LRH/GRH or any components of the outer IP and UDP headers.
- Where the end-to-end mCRC would be redundant (e.g., PSP encapsulation with an integrity check), it is omitted. When carried by ESUN encapsulation, mCRC is required because the frame is not end-to-end protected by an unchanging CRC.

---

## 4. Key Protocol Innovations

### 4.1 Explicit Multipath with Per-Path Windows

- The sender maintains multiple **Paths** within a single connection (QP).
- Each Path has its own sliding window (PWND[p]), packet tracker, RTT estimate, and selective ACK state.
- The **entropy value** (UDP source port) in the encapsulation header directs packets across different ECMP routes without switch-level support.
- Path state is tracked with fixed-size bitmaps — memory requirements are bounded regardless of how many paths are active.
- **Silence on a path** is distinguishable from transient congestion: a path that stops ACKing can be declared failed and its traffic moved to surviving paths.
- As bandwidth-delay product grows, the sender scales by **adding paths** rather than enlarging per-path windows, keeping each path a fixed-size resource and spreading traffic across more available fabric.

### 4.2 Connection Multiplexing Through Tags

- A single Meta-RoCE QP can carry multiple independent message streams called **Tags**.
- Each Tag has its own MSN/CSN namespace and completion ordering.
- A stall on one Tag — due to packet loss or a receiver that is not ready — **does not block progress on other Tags**.
- Tags correspond to the communicators or collective operations in modern training workloads.

### 4.3 Relaxed-Order Data Delivery

- Every data packet carries its offset within the message (POSN).
- Data can be placed at its final memory location as it arrives, without waiting for earlier packets.
- For RDMA Write operations, each packet carries the destination memory address, R Key, and length — eliminating the need for large on-NIC reorder buffers whose size would otherwise grow with the bandwidth-delay product.
- The receiver does not stall waiting for earlier packets before processing later ones, avoiding head-of-line blocking at the NIC.

### 4.4 Custom Congestion Control (Baseline AIMD + Programmable Extension)

**Baseline CC:**
- Sender-driven, window-based AIMD (Additive Increase, Multiplicative Decrease) protocol.
- Responds to ECN marks and packet loss.
- Manages windows at per-QP and per-path granularity.
- Per-packet reaction: increment fractional QWND by ε on uncongested ACK; decrement QWND by β×QWND on congested ACK; decrement by λN on N packet losses.
- Parameters: ε=1 (default), β=1/2 (default), λ=1 (default), fast_start_burst=4 (default).

**Receiver-Driven Rate Limiting (RCN):**
- Receiver computes a TargetRate (fair-share bitrate) and sends it in every ACK.
- TargetRate = Total Link Rate (Gbps) / Estimated Concurrent Senders + Target Rate Offset.
- Sender converts TargetRate to a QWND_max cap: QWND_max = max(QWND_min, γ × TargetRate × (RateWeightedRTT + ω)).
- This allows fast convergence during incast without relying on PFC.

**Advanced/Programmable CC (optional):**
- Programmable logic can modify QWND, PWND[p], and CC parameters (ε, β, λ).
- Can implement TCP Cubic, Hybla, Swift, or other custom algorithms.
- Uses signals exposed by hardware including RTT, ECN marks, retransmission counts, in-flight counts, etc.

### 4.5 Selective Acknowledgment and Per-Path Retransmission

- Receiver reports which packets have arrived using a **per-path 256-bit bitmap** (SelAckBitVector).
- CumulativeFSN is the last contiguously ACKed FSN (offset: receiver sends rcv.nxt-1 or less).
- MaxFSN is the highest FSN that has been fully ACKed (received and will be delivered to memory).
- Sender retransmits only the missing packets using the bitmap.
- Separate retransmission cursors: snd.una (next contiguously ACKed), snd.cur (next retransmission cursor), snd.nxt (next FSN to send).
- On RTO expiration, snd.cur is reset to snd.una and the entropy value is changed.

### 4.6 RNR (Receiver Not Ready) Protocol

Two distinct RNR types:
- **BRNR (Buffer RNR):** Valid request received, but RWQEs needed to process the request are not available. Rendezvous resource may be available. ACK carries RNR bitset identifying specific FSNs that were network-delivered but could not be delivered to application. The sender must return the corresponding frame for BRNR retransmission with a new FSN.
- **HRNR (Hardware RNR):** QP is not initialized or not present in necessary cache. Hardware resources are unavailable. No RNR bitset is sent. All messages on all tags must wait for QP to be activated.

RNR-Cancel: A new packet type sent when the receiver becomes ready after an RNR condition. The RNR-Cancel is unreliable (not retransmitted); recovery from RNR by probing is still appropriate.

---

## 5. High-Level Architecture

```
+----------------------------------------------------------+
|                     Application                          |
|                     (external)                           |
+----------------------------------------------------------+
|                 Application Interface                    |
|         Send/Receive, RDMA Write/Read, Atomics           |
+----------------------------------------------------------+
|                       Ordering                           |
|            Tags, MSN, CSN, completion ordering           |
+----------------------------------------------------------+
|                      Reliability                         |
|       Selective ACK, retransmission, RNR recovery        |
+----------------------------------------------------------+
|                  Congestion Control                      |
|          QWND, PWND, ECN, receiver rate limiting         |
+----------------------------------------------------------+
|                     Multi-Path                           |
|           Path selection, entropy, port failover         |
+----------------------------------------------------------+
|                      Network                             |
|  Eth | IPv6/IPv4/ESUN/PSP | UDP:2766 | BTH | METH | mCRC |
|                     (external)                           |
+----------------------------------------------------------+
```

**Key data flow:**

```
Initiator (Sender)                     Responder (Receiver)
    |                                         |
    |-- [Write/Send/Read Request] ----------->|
    |   Eth|IP|UDP|Base Hdr|METH|RETH|Payload|mCRC
    |   Per-path FSN, QP+Tag MSN, POSN        |
    |                                         |-- deliver to memory (POSN-addressed)
    |<-- [Selective ACK] ---------------------|
    |   SAETH: CFSN, SelAckBitVector, MaxFSN  |
    |   CDMSN, TargetRate, ActivePortSet      |
    |                                         |
    |-- [Retransmit missing FSNs if needed] ->|
    |   Same PathID + FSN, new entropy ok     |
```

---

## 6. Implementation Scope

This implementation does **NOT** include all features from the Meta RoCE specification v0.97. See **`docs/07-feature-status.md`** for a complete list of unimplemented features, including:

- **RDMA Read** (opcodes 0xCC-0xCF) — Write and Send operations only
- **Atomic operations** (FetchAdd, CmpSwap opcodes 0xD2-0xD5) — application-level synchronization only
- **Tags** (stream multiplexing within a QP) — Tag field always 0, single stream per QP
- **HRNR** (Hardware RNR) — using software BRNR instead
- **RNR-Cancel packets** — recovery via timeout/retransmission only
- **In-protocol Ping (Echo)** — using out-of-band diagnostics
- **Programmable Congestion Control** — fixed AIMD+RCN algorithm

For rationale, workarounds, and impact of each gap, see `docs/07-feature-status.md`.

---

## 8. Functional Areas / Protocol Subsystems

| Subsystem | Spec Chapter | Key Concepts |
|-----------|-------------|-------------|
| Sequence Numbers | Ch. 2 | MSN, POSN, CSN, FSN and their scopes |
| Ordering | Ch. 3 | Message delivery ordering, Tag isolation, completion modes |
| Reliable Delivery | Ch. 4 | mCRC, ACK generation, SACK, per-path timeout, RTO, RNR |
| Error Handling | Ch. 5 | Retriable errors, message-fatal errors, NAK syndromes |
| Congestion Control | Ch. 6 | Baseline AIMD, Fast Start, Advanced/Programmable CC, RCN |
| Multi-Path | Ch. 7 | Path entropy, path selection, path state machine, multi-port failover |
| Packet Headers | Ch. 8 | Base header, METH, RETH, SAETH, RNR-Cancel, Control, AtomicETH |
| Feature Summary | App. A | MUST/Should/may requirements for all features |
| Verbs Integration | App. B | QP type, profile selection, tags, multi-port API |

---

## 9. Glossary of Meta-RoCE-Specific Terms

Terms that do not exist in standard RoCEv2 or have significantly different meanings in Meta-RoCE:

| Term | Definition |
|------|-----------|
| **Tag** | An independent message stream within a single QP, with its own MSN/CSN namespace, work queue, and completion ordering. When tags are not supported, assume tag is zero. |
| **FSN (Flow Sequence Number)** | Per-path packet sequence number, incrementing on every packet within a path. The unit of acknowledgment and retransmission. Starts at zero and can wrap. Scoped to a (QP, Path). |
| **MSN (Message Sequence Number)** | Unique identifier for each message, incrementing on every WQE initiated within a QP+Tag. Scoped to QP+Tag. Can wrap. |
| **POSN (Packet Offset Sequence Number)** | Sequence number within a message, indexing payload-sized increments. Starts at zero per message. Cannot wrap. Maximum message size 256 MB (16-bit POSN, 4096-byte payload). |
| **CSN (Completion Sequence Number)** | Tracks in-order completion of Receive-WQE-consuming operations at the responder. Scoped per QP+Tag. |
| **CDMSN (Cumulative-Responder-Delivered-MSN)** | The cumulative responder delivered MSN — the highest MSN of in-order received and delivered messages. Carried in ACKs. Scoped per QP+Tag. |
| **METH (Meta Extended Transport Header)** | The Meta-RoCE data packet header carrying FSN, FSN-Clear (UNA), Tag, A/R/T bits, POSN, CSN, MSN, Rate Hints, and Transmit Timestamp. |
| **SAETH (Selective Acknowledgment Extended Transport Header)** | The Meta-RoCE acknowledgment header carrying CNP count, Tag, CumulativeFSN, MaxFSN, AckStatus, CDMSN, ActivePortSet, Rate Hints, Echo Timestamp, and optional FSN/RNR bit vectors. |
| **Path** | A virtual network path identified by a Path ID within a QP. Each path has an independent FSN space, PWND, RTT estimate, and packet tracker. Paths use distinct entropy values to traverse different physical network paths. |
| **Path ID** | A sequential identifier scoped to a QP (not shared across QPs). Identifies which set of FSNs a packet belongs to. |
| **Entropy value** | The UDP source port value used to influence ECMP hashing in the network. Different entropy values make it likely that packets traverse different physical paths. The entropy value is NOT the identifier of the path — it may be changed without changing the path ID. |
| **QWND** | QP-Level Window. The total outstanding packets allowed on the entire QP. QWND = sum of all PWND[p] values. |
| **PWND[p]** | Per-Path Window. Limits outstanding packets on a single path. PWND[p] values sum to QWND. |
| **AWND[p]** | Available window for path p: AWND[p] = PWND[p] + snd.inflate[p] - (snd.nxt[p] - snd.una[p]). |
| **QWND_max** | The maximum QWND value set by the Receiver-Driven Rate Limiting mechanism based on TargetRate. |
| **PWND_max** | Configurable maximum per-path window to limit excessive single-path window growth. |
| **PWND_floor** | Minimum PWND value below which RCN-based reduction is prevented, to protect low-numbered paths. |
| **TargetRate** | The receiver-computed expected fair-share bitrate (Gbps) communicated to the sender in every ACK. Used to compute QWND_max. |
| **RateWeightedRTT** | Per-QP smoothed RTT estimate computed as the average of per-path RTT samples. Used to convert TargetRate to QWND_max. |
| **RCN (Receiver Congestion Notification)** | The mechanism by which the receiver signals a TargetRate to the sender to control the sender's QWND_max. Separate from ECN-based CC. |
| **mCRC** | Meta-RoCE CRC. A CRC-32 that is pre-inverted and post-inverted, using the Ethernet CRC polynomial. Covers Meta-RoCE headers and data only. Placed at the end of the UDP payload. |
| **Fast Start** | A window probing mechanism at the beginning of a transmission, where PWND and QWND are incremented on each packet sent (rather than on ACK). Exits on first ACK or RTT elapsed. |
| **snd.nxt[p]** | Next scheduled FSN: the lowest FSN that has not yet been sent on path p. |
| **snd.una[p]** | Next contiguously ACKed FSN: the lowest FSN not yet contiguously acknowledged on path p. |
| **snd.cur[p]** | Next retransmission cursor: the next FSN that may be retransmitted in response to a selective ACK. Reset to snd.una on RTO. |
| **snd.inflate[p]** | The number of FSNs between snd.una[p] and snd.nxt[p] that have been selectively ACKed. |
| **UNA (Unacknowledged Pointer / FSN Clear)** | The snd.una value carried in data packets, telling the receiver the lowest FSN not yet contiguously ACKed. Allows the receiver to free per-FSN state. |
| **BRNR (Buffer RNR)** | Receiver Not Ready due to missing buffer (RWQE not posted), but the QP and path state are present in cache. Carries an RNR bitset in the ACK identifying specific FSNs that were network-delivered but could not be delivered. |
| **HRNR (Hardware RNR)** | Receiver Not Ready because the QP is not initialized or not present in necessary cache. No RNR bitset sent. All tags must wait. |
| **RNR-Cancel** | A new packet type (opcode 0xd0) sent by the receiver when it becomes ready after an RNR. Unreliable — not retransmitted. |
| **Eager Tail Retransmission** | An optimization where the sender eagerly retransmits the last packet when the connection has been idle longer than RTT but less than RTO, to avoid tail latency from tail loss. |
| **Alternate Path Retransmission** | On RTO, the sender changes the entropy value (and optionally the output port) to avoid a failed physical path. The path ID and FSN remain unchanged. |
| **vRWQE (Virtual Receive-WQE)** | The Meta-RoCE internal state complementary to an RWQE but allocated upon receipt of a message from the remote, rather than upon posting of an actual WQE. |
| **Virtual Completion / vWQE** | The state maintained internally for message types that do not post a completion to the job. A virtual completion exists when the message is complete. |
| **Completion Fence** | A per-WQE bit that ensures this specific WQE is completed only when all prior WQEs in the queue have completed. |
| **ESUN** | An encapsulation type for Meta-RoCE. When ESUN encapsulation is used, mCRC is required because the frame is not end-to-end protected by an unchanging CRC. |
| **Multiplane** | A multi-port topology where each local port sends to exactly one port at the receiver; different paths through the network on distinct planes may use the same source and destination addresses. |
| **Multiport** | A topology where each port on the sender may be configured to send across a network that enables directly addressing one or more ports at the receiver; different paths have different source and destination addresses. |
| **Active Port Set** | A bitfield in ACKs representing the ready status of each port on a multi-port NIC. Bit set (1) means port is active. |
| **Topology Wiring Table** | A matrix specifying which local ports can reach which remote ports. Used by the failover algorithm to find alternate port pairs. |
| **ρ (rho)** | Additive offset to the expected RTO. Accounts for processing delays not captured by the measured RTT, e.g., the time difference between when the retransmission timer is set and when the timestamp is placed on the outgoing packet. |
| **ω (omega)** | Fixed headroom (in units of delay) in the RCN QWND_max calculation. Accounts for processing delays not in RTT estimates (e.g., delay in fetching packet payload via DMA). |
| **γ (gamma)** | RCN proportionality factor (≥1) that permits a looser limit to QWND_max proportional to RTT, reducing the influence of RCN by relying more on ECN-based CC. |
| **InProtocol Ping (Echo)** | Control packet type used for firmware-to-firmware connectivity probing. Type 0 = echo request, type 1 = echo response. The payload is echoed into the response. |
| **Rate Hints / Desired Rate** | A field in the METH data header representing the approximate expected speed of the transfer in Gbps. Used by the receiver to compute TargetRate. |
| **CNP (Congestion Notification Packet)** | Field in the ACK header counting CE-marked packets received since the last ACK was sent. Carried as a 4-bit count. |
| **Receive-WQE-Consuming Operation** | Operations that require the receiver to have posted a RWQE: Send, Write-with-Immediate. These post completions at the responder. |
| **non-Receive-WQE-Consuming Operation** | Operations that do not require an RWQE at the responder: Write, Read, Atomics. These generate virtual completions at the responder. |
| **MINRTT.QP** | Minimum RTT observed across all paths for this QP; may be cleared when read by the Advanced CC algorithm. Used as a delay baseline. |
| **SRTT.QP / SRTT[p]** | Smoothed RTT estimate per QP or per path. Maintained by exponential moving average on each ACK. |
| **MDEV.QP / MDEV[p]** | Mean deviation of RTT estimate per QP or per path. Used in RTO computation. |

---

## 8. Supported Operations

| Operation | Details |
|-----------|---------|
| **SEND** | With and without immediate, with and without Tags. Requires RWQE at responder. |
| **RDMA Write** | With and without immediate. Write-with-immediate requires RWQE. |
| **RDMA Read** | With and without immediate. Read request may optionally carry an immediate header. |
| **Atomics** | FetchAdd, CmpSwap, and extended operations (XOR, OR, AND). Single-packet messages (POSN always zero). |
| **RNR-Cancel** | Sent by receiver when it becomes ready after an RNR. |
| **Selective ACK** | Acknowledgment packet with per-path 256-bit bitmap. |
| **Echo (Ping)** | Firmware-to-firmware control packet for connectivity probing. |

---

## 9. Encapsulation

Meta-RoCE may be encapsulated as:

```
Primary (required):   L2 | IPv6    | UDP:2766 | Meta-RoCE Headers | Payload | mCRC | FCS
Alternative:          L2 | IPv4    | UDP:2766 | Meta-RoCE Headers | Payload | mCRC | FCS
Alternative:          L2 | ESUN   |           | Meta-RoCE Headers | Payload | mCRC | FCS
Redundant CRC (omit): L2 |         |           | Meta-RoCE Headers | Payload |      | FCS
PSP encapsulation:    L2 | L3     | UDP | PSP | Meta-RoCE Headers | Payload | PSP ICV | FCS
```

- IPv6/UDP is **MUST**; IPv4/UDP is **Should**; Ethernet-direct (no IP) and ESUN are **may**.
- ECN-capability on data packets **MUST** be provided through the ECT(0) codepoint (per IETF RFC 3168 §5).
- UDP checksum must be either zero or correct; a packet with zero UDP checksum value must not be rejected.
- A NIC will provide a link MTU of 4200 bytes or greater as default, sufficient for a QP MTU of 4096 bytes plus protocol headers.
- Supported RDMA MTU sizes: 4096 (MUST), 1024 (Should), 2048 (Should), 8192 (Should).
- MTU must be agreed on between both endpoints before posting WQEs; MTU cannot be changed after the first WQE on a QP.

---

## 10. Spec Version History Summary

| Version | Date | Key Changes |
|---------|------|-------------|
| 0.97 | April 6, 2026 | ESUN encapsulation, SACK cursor fraction, RNR data recovery figures, ρ rho required, hop-count retransmission marking, Active Port Set in ACK, echo packet path count, unordered mode appendix |
| 0.96 | December 18, 2025 | snd.cur advances after RTO reset, stale ACK discard, BRNR description extended |
| 0.95 | October 8, 2025 | Invalid mCRC discard, ack/data traffic class separation, CDMSN cases, reserved fields handling, Path ID Unsupported NAK code |
| 0.94 | September 26, 2025 | Concurrent reads sequence diagram, mixed writes/sends, completion ordering table, IPv4/PSP/Ethernet encapsulation |
| 0.93 | July 14, 2025 | MTU must be identical at both endpoints, removed strict order mode, PWND_max, omega parameter, fast start idle re-entry |
| 0.92 | May 30, 2025 | Ack request bit on last frame of message, FSN clear for RNR resync |
| 0.91 | March 30, 2025 | Write-with-immediate-present opcode, HRNR does not free FSNs |
| 0.9 | March 20, 2025 | CRC algorithm, UDP port 2766, retransmission marking in TTL, path window increment rules |
| 0.8 | December 10, 2024 | Selective ACK retransmission policy options, clear_rnr_state removed, selectively increasing path windows |
| 0.71 | September 30, 2024 | Retransmission/RCN signals for Advanced CC, ACK field swap vs copy clarification |
| 0.7 | September 14, 2024 | Deleted per-packet alternate path retransmission, Tag added to ACK |
| 0.63 | August 14, 2024 | Scope ordering MSN by QP+Tag, path state diagram |
| 0.50 | May 8, 2024 | QWND/PWND congestion control design, sender-based reliability timers |
| 0.4 | May 2, 2024 | RNR protocol, ordering protocol defined |
