# Meta-RoCE Protocol Reference

**Specification:** Meta-RoCE Protocol for AI Accelerators v0.97 (Draft)
**Classification:** Meta Proprietary and Confidential. Shared with AMD under NDA.

---

## 1. Packet Header Formats

### 1.1 Bit Ordering Convention

In all header diagrams, bit markers in the heading (31 down to zero) represent the significance of the bit if each 32-bit word (corresponding to a row in the diagram) is stored in **most-significant-byte order** (big endian). For example, to extract path ID and opcode from a packet pointer `p`:

```c
void extract_path_id_and_opcode(void *p, int *path_id, int *opcode) {
    uint32_t w = ntohl(((uint32_t *)p)[0]);
    *path_id = w & 0xffff;
    *opcode  = w >> 24;
}
```

All Meta-RoCE packets (data, acknowledgment, control) include padding if necessary to reach a multiple of 4 bytes, and a Meta-RoCE mCRC of 32 bits at the end of the UDP payload.

**Reserved fields** must be set to zero by transmitters. Receivers must not reject packets where reserved fields have nonzero values.

---

### 1.2 Base Header (BTH)

Present in every Meta-RoCE packet.

```
 31      24 23    21 20    16 15             0
+---------+--------+--------+----------------+
| Opcode  |  Rsvd  |  Ver   |    PathID      |  Word 0
+---------+--------+--------+----------------+
|              Destination QP                |  Word 1
+--------------------------------------------+
|               Source QP                    |  Word 2
+--------------------------------------------+
```

| Field | Bits | Description |
|-------|------|-------------|
| Opcode | [31:24] | 8-bit opcode: bits [7:5] = transport type = `110`; bits [4:0] = operation |
| Reserved | [23:21] | Must be zero on TX; ignored on RX |
| Version | [20:16] | Must be zero; packets with nonzero version must be silently discarded and counted |
| PathID | [15:0] | Sequential Path ID associated with this data flow. Identifies which path (set of FSNs) this packet belongs to. Scoped to QP. |
| Destination QP | [31:0] | Determines the context for the data at the recipient |
| Source QP | [31:0] | Identifies the sender; used for error responses |

**Notes:**
- PathID is 16 bits; implementations need not support 4,096 paths.
- Implementations need not support all 65,536 possible path IDs.
- In asymmetric multi-address environments, the path may have different source/destination addresses for data vs. ACK traffic.

---

### 1.3 Data Packet Header: METH (Meta Extended Transport Header)

Present on all data packets (Send, Write, Read Response, Atomics, RNR-Cancel data path). Follows the Base Header.

```
 31      24 23    21 20    16 15             0
+---------+--------+--------+----------------+
| Opcode  |  Rsvd  |  Ver   |    PathID      |  Base Header Word 0
+--------------------------------------------+
|              Destination QP                |  Base Header Word 1
+--------------------------------------------+
|               Source QP                    |  Base Header Word 2
+--------------------------------------------+
|    Flow Sequence Number (FSN) [31:16]      |
|    Flow Sequence Number Clear (UNA) [15:0] |  METH Word 0
+--------------------------------------------+
|  Tag  |A|R|T| Rsvd  | Packet Offset Seq # |
|       | | | |       |     (POSN) [15:0]    |  METH Word 1
+--------------------------------------------+
| Completion Sequence Number (CSN) [31:16]   |
| Message Sequence Number (MSN) [15:0]       |  METH Word 2
+--------------------------------------------+
|            Rate Hints [31:0]               |  METH Word 3
+--------------------------------------------+
|         Transmit Timestamp [31:0]          |  METH Word 4
+--------------------------------------------+
```

| Field | Bits (within METH) | Description |
|-------|------|-------------|
| FSN (Flow Sequence Number) | [31:16] of Word 0 | Per-path packet sequence number. Incrementing on every packet within a path. Starts at zero and can wrap. |
| UNA (FSN Clear) | [15:0] of Word 0 | snd.una: the sender's next contiguously acknowledged FSN. Tells receiver it may free per-FSN state for FSNs below this value. |
| Tag | [31:28] of Word 1 | Identifies the sub-queue (tag) within the QP. Zero when tags not supported. |
| A (Ack Request / Flush Ack) | Bit 27 of Word 1 | Set to request an immediate acknowledgment with echoed timestamp. |
| R (Retransmission bit) | Bit 26 of Word 1 | Set if this packet has been previously transmitted. Counted at receiver as necessary (not previously seen) or spurious. |
| T (Timeout bit) | Bit 25 of Word 1 | Set if this packet was scheduled for retransmission via timeout (not SACK). |
| Reserved | [24:16] of Word 1 | Zero on TX; ignored on RX |
| POSN (Packet Offset Seq #) | [15:0] of Word 1 | Sequence number within the message. Starts at zero per message. Cannot wrap. Indexes payload-sized increments. |
| CSN (Completion Seq #) | [31:16] of Word 2 | Completion sequence number: tracks Receive-WQE-consuming operations at responder. Ignored in Write headers. |
| MSN (Message Seq #) | [15:0] of Word 2 | Message sequence number. Unique identifier for each message within QP+Tag. |
| Rate Hints | [31:0] of Word 3 | Approximate expected speed in Gbps. Set as QWND × 4096 × 8 / RTT ns in normal CC operation. Zero = field ignored. |
| Transmit Timestamp | [31:0] of Word 4 | Approximately nanosecond-precision transmit timestamp. Echoed in ACK to enable RTT measurement. Free-running clock; not required to be synchronized between stations. |

**Rate Hints computation (for non-fast-start, non-end-of-transfer):**
```
RateHint = QWND * 4096 * 8 / RTT  [bits per second → Gbps]

Approximation using shift when RTT in range [6144ns, 12288ns]: use 8192ns → shift by 2
When RTT in range [12288ns, 24576ns]: shift left by 1
Must clamp to [1, link_capacity_Gbps]
```

**At end of transfer** (this is the last WQE and few packets remaining): set Rate Hints to zero.

---

### 1.4 Read Request and Write Headers: RETH

**Implementation Note:** RDMA Read operations (opcodes 0xCC, 0xCD, 0xCF) are **NOT IMPLEMENTED**. Only RDMA Write uses RETH. Read Request packets will generate NAK-Invalid-Operation. See `docs/07-feature-status.md` for details.

For RDMA Read Request and RDMA Write operations, the RETH (RDMA Extended Transport Header) is appended after the METH header:

```
 31      24 23    21 20    16 15             0
+---------+--------+--------+----------------+
| Opcode  |  Rsvd  |  Ver   |    PathID      |  Base Header
+--------------------------------------------+
|              Destination QP                |
+--------------------------------------------+
|               Source QP                    |
+--------------------------------------------+
|    Flow Sequence Number (FSN) [31:16]      |
|    Flow Sequence Number Clear (UNA) [15:0] |  METH
+--------------------------------------------+
|  Tag  |A|R|T| Rsvd  |     POSN [15:0]     |
+--------------------------------------------+
|      CSN [31:16]    |     MSN [15:0]       |
+--------------------------------------------+
|            Rate Hints [31:0]               |
+--------------------------------------------+
|         Transmit Timestamp [31:0]          |
+--------------------------------------------+
|         Message Address [63:32]            |  RETH
+--------------------------------------------+
|         Message Address [31:0]             |
+--------------------------------------------+
|              R Key [31:0]                  |
+--------------------------------------------+
|           Message Length [31:0]            |
+--------------------------------------------+
```

| RETH Field | Description |
|-----------|-------------|
| Message Address [63:0] | 64-bit virtual address of the destination (write) or source (read) buffer |
| R Key | Remote memory key authorizing access to the memory region |
| Message Length | Total length of the overall write or read request in bytes |

**Rules:**
- The sender must provide **identical** RETH fields (address, R Key, length) in all packets of the same write message.
- The receiver must validate the RETH fields at least once per message.
- An implementation may use a cached, already validated copy of the RETH information.

---

### 1.5 Immediate Data Header (ImmDt)

A single 32-bit field appearing in packets carrying immediate data:

```
 31                              0
+----------------------------------+
|        Immediate Data [31:0]     |
+----------------------------------+
```

- For Send-with-Immediate: ImmDt appears in the last packet of the message (no RETH header).
- For Write-with-Immediate: ImmDt appears in the last packet (after RETH).
- For Read-Request-with-Immediate: ImmDt follows RETH in the request packet (optional support).
- **Byte order:** Sent in big endian order. The verbs work request expects big endian order from the application. No byte swap is performed by the protocol.

---

### 1.6 Ack Packet Format (SAETH — Selective Acknowledgment Extended Transport Header)

The full ACK packet layout:

```
 31      24 23    21 20    16 15             0
+---------+--------+--------+----------------+
| Code:0xd1|  Rsvd |  Ver   |    PathID      |  Base Header Word 0
+--------------------------------------------+
|              Destination QP                |  Base Header Word 1
+--------------------------------------------+
|               Source QP                    |  Base Header Word 2
+--------------------------------------------+
| Rsvd |CNP:CE|   Tag    |  Cumulative FSN   |  SAETH Word 0
+--------------------------------------------+
|     Max FSN         | Ack Status |  Rsvd   |  SAETH Word 1
+--------------------------------------------+
|  Cumulative Responder Delivered MSN(CDMSN) |
|              Active Port Set               |  SAETH Word 2
+--------------------------------------------+
|         Reserved         |   Rate Hints    |  SAETH Word 3
+--------------------------------------------+
|         Echo Timestamp [31:0]              |  SAETH Word 4
+--------------------------------------------+
|         FSN Bit Vector [31:0]              |  Optional FSN
+--------------------------------------------+  Bit Vector
|         FSN Bit Vector [63:32]             |  (256 bits =
+--------------------------------------------+  8 x 32-bit words;
               ...                              present if Ack
+--------------------------------------------+  Status is SACK
|         FSN Bit Vector [255:224]           |  or BRNR)
+--------------------------------------------+
|         FSN RNR Bit Vector [31:0]          |  Optional RNR
+--------------------------------------------+  Bit Vector
|         FSN RNR Bit Vector [63:32]         |  (256 bits;
+--------------------------------------------+  present only if
               ...                              Ack Status is
+--------------------------------------------+  BRNR; requires
|         FSN RNR Bit Vector [255:224]       |  FSN Bit Vector)
+--------------------------------------------+
```

| Field | Bits | Description |
|-------|------|-------------|
| Code | [31:24] of BH Word 0 | 0xd1 — the opcode for Selective ACK |
| PathID | [15:0] of BH Word 0 | Echo of the path identifier from the data packet being acknowledged |
| Destination QP | BH Word 1 | Echo of Source QP from data (swapped) |
| Source QP | BH Word 2 | Echo of Destination QP from data (swapped) |
| Rsvd | [31:28] of SAETH W0 | Zero |
| CNP:CE count | [27:24] of SAETH W0 | 4-bit count of CE-marked packets received since last ACK sent. Incremented on each CE-marked packet; cleared when read. |
| Tag | [23:16] of SAETH W0 | Tag field providing scope for the CDMSN field below |
| Cumulative FSN | [15:0] of SAETH W0 | CumulativeFSN: the FSN from which bit vector operations are applied as offset. Monotonically increasing. Should equal rcv.nxt-1. |
| Max FSN | [31:16] of SAETH W1 | MaxFSN: the highest FSN that has been fully acknowledged (received and will be delivered to memory). Optimization permitting sender to skip bit vector for high FSNs. |
| Ack Status | [15:8] of SAETH W1 | ACK/NAK/BRNR/HRNR/Error status code (see Table 8.3) |
| Reserved | [7:0] of SAETH W1 | Zero |
| CDMSN | [31:16] of SAETH W2 | Cumulative Responder Delivered MSN. The highest MSN of in-order received and delivered messages at the responder. Associated with the Tag field. |
| Active Port Set | [15:0] of SAETH W2 | Bitfield representing ready status of each port on a multi-port NIC. Set (1) = port active. Zero = no active port set support or no multi-port. |
| Reserved | [31:16] of SAETH W3 | Zero |
| Rate Hints | [15:0] of SAETH W3 | TargetRate: receiver's desired rate in Gbps. Sender uses to compute QWND_max. |
| Echo Timestamp | [31:0] of SAETH W4 | Echoed timestamp from the most recently received data packet's Transmit Timestamp field. Used by sender to compute RTT. |
| FSN Bit Vector | 256 bits (8 words) | Optional. Present when Ack Status is Out-of-Order (0x1) or BRNR. The zeroth bit (LSB of Word [31:0]) represents the packet at CumulativeFSN+1. A 1 = received and will be delivered; a 0 = not received or negatively ACKed. |
| FSN RNR Bit Vector | 256 bits (8 words) | Optional. Present only when Ack Status is BRNR. A 1 = packet received on the network but could not be delivered (RNR'd). Cannot appear in same bit as FSN Bit Vector. |

**Minimum ACK size:** Any received Meta-RoCE ACK that is at least 20 bytes long must have the cumulative FSN processed.

**FSN bit vector bit ordering (per spec §8.5.9):**

```c
struct ack_header {
    uint16_t cumulative_fsn;
    uint32_t fsn_bit_vector[8];
};

bool is_bit_set(const struct ack_header *a, uint8_t bit) {
    uint32_t w = ntohl(a->fsn_bit_vector[bit/32]);
    return ((w>>(bit % 32)) & 0x1);
}

bool is_fsn_bit_set(const struct ack_header *a, uint16_t fsn) {
    uint16_t offset = fsn - a->cumulative_fsn - 1;
    return offset < 256 && is_bit_set(a, (uint8_t)offset);
}

bool is_fsn_acked(const struct ack_header *a, uint16_t fsn) {
    return !after(fsn, a->cumulative_fsn) || is_fsn_bit_set(a, fsn);
}
```

**ACK discard conditions** (an ACK may be discarded without processing if any of the following are true):
- `before(MaxFSN, CumulativeFSN)` — this ack has at best has old information.
- `!before(CumulativeFSN, snd.nxt)` — this sender has not sent the packet being cumulatively ACKed.
- `before(MaxFSN, CumulativeFSN)` — receiver sent an ack as if window is greater than half the sequence space.
- `RTT_meas > min(2 × MaxRTO, 64 × (RTT[p] + mdev))` — the ack was generated in response to a packet the sender sent more than 64 round trip times ago.

---

### 1.7 Ack Status Codes (Table 8.3)

| Ack Status [7:5] | Ack Status [4:0] | Description | FSN Bitset | RNR Bitset |
|---------|---------|-------------|-----------|-----------|
| 000 | 00000 | ACK; all data in sequence; no FSN bitset follows | No | No |
| 000 | 00001 | ACK; some data received out of order; FSN bitset follows | Yes | No |
| 001 | TTTTT | HRNR-NAK; TTTTT = encoded backoff time; no bitset follows | No | No |
| 010 | TTTTT | BRNR-NAK; TTTTT = encoded backoff time; FSN and RNR bitsets follow | Yes | Yes |
| 011 | 00000 | NAK: Path ID unsupported / too large | No | No |
| 011 | 00001 | NAK: Address invalid / Access Error (RoCEv2: Remote Access Error) | No | No |
| 011 | 00010 | NAK: Invalid Request | No | No |
| 011 | 00011 | NAK: Operational Error (RoCEv2: Remote Operational Error) | No | No |
| 011 | 00100 | NAK: Reserved | No | No |
| 011 | 00101 | NAK: Reserved | No | No |
| 011 | 0011x | NAK: Reserved | No | No |

**RNR Backoff Time Encoding (Table 8.4):**

| Backoff Time [4:0] | As Integer | Description |
|---------|---------|-------------|
| 00000 | 0 | 0 μs: Immediate retry (transient failure) |
| 0xxxx | 1-15 | 5 μs × 2^n: 10 μs to 163.84 ms |
| 1xxxx | ≥16 | Reserved |

**ACK/NAK Header Fields by Type (Table 8.5):**

| Field | ACK | SACK | BRNR | HRNR | Path ID Error | Inval/Op/Addr Error |
|-------|-----|------|------|------|---------------|---------------------|
| Opcode | 0xd1 | 0xd1 | 0xd1 | 0xd1 | 0xd1 | 0xd1 |
| Version | 0 | 0 | 0 | 0 | 0 | 0 |
| Path ID | Set normally, echoing received path ID |
| Dest QP | Set normally, from received source QP |
| Source QP | Set normally, from received destination QP |
| Reserved (all) | 0, Ignored |
| CNP | May be set normally; one if congestion marked, else zero |
| Tag | Set normally | Set normally | Tag of packet that led to NAK |
| Cumulative FSN | Set normally | Set normally | FSN of packet that led to NAK |
| Max FSN | Set normally | Set normally | FSN of packet that led to NAK |
| Ack Status | 0 | 1 | 0x40-0x5f | 0x20-0x3f | 0x60 | 0x61-0x63 |
| CDMSN | Set normally | Set normally | Reserved | MSN of packet led to NAK |
| Rate Hints | Set normally | Set normally | Reserved | Supported path count | Reserved |
| Echo Timestamp | Set normally |
| FSN Bitset | Not present | Present | Present | Not present |
| RNR Bitset | Not present | Not present | Present | Not present |

---

### 1.8 RNR-Cancel Packet (Receiver Is Ready)

```
 31      24 23    21 20    16 15             0
+---------+--------+--------+----------------+
| Code:0xd0|  Rsvd |  Ver   |    PathID      |  Base Header
+--------------------------------------------+
|              Destination QP                |
+--------------------------------------------+
|               Source QP                    |
+--------------------------------------------+
| Paths available  |   Tag    |  Posted CSN  |  RNR-Cancel Header
+--------------------------------------------+
|             Rate Hints [31:0]              |
+--------------------------------------------+
```

| Field | Description |
|-------|-------------|
| Code | 0xd0 — Opcode for RNR-Cancel / Receiver Is Ready |
| PathID | Path identifier (may be zero; no FSN sequence numbers used) |
| Paths available | Number of supported TX paths |
| Tag | Tag identifier |
| Posted CSN | CSN of the most recently posted RWQE |
| Rate Hints | Receiver's current rate hints |

**Notes:**
- The RNR-Cancel message is **unreliable** — it is not retransmitted.
- The initiator is expected to retry even without receipt of RNR-Cancel.
- RNR-Cancel is an optimization: (a) increases default backoff interval for RNR to reduce probing traffic; (b) enables near-immediate restart as soon as receiver becomes ready.

---

### 1.9 Control Packet Header

Used for firmware-to-firmware control messages (e.g., ping/echo). Sent unreliably.

```
 31      24 23    21 20    16 15             0
+---------+--------+--------+----------------+
| Code:0xdf|  Rsvd |  Ver   |    PathID      |  Base Header
+--------------------------------------------+
|              Destination QP                |
+--------------------------------------------+
|               Source QP                    |
+--------------------------------------------+
|     Type        |   Response Identifier    |  Control Header
+--------------------------------------------+
|         Transmit Timestamp [31:0]          |
+--------------------------------------------+
|            Control Packet Data             |
+--------------------------------------------+
|         Control Packet Data - as needed    |
+--------------------------------------------+
```

**QP numbers in control packets need not be validated by hardware.** The path ID is not necessary (no FSN sequence numbers); it may be set to zero.

---

### 1.10 Ping (Echo) Control Packet Headers

Echo request (Type=0) and echo response (Type=1) share the same header format:

```
 31      24 23    21 20    16 15             0
+---------+--------+--------+----------------+
| Code:0xdf|  Rsvd |  Ver   |    PathID      |  Base Header
+--------------------------------------------+
|              Destination QP                |
+--------------------------------------------+
|               Source QP                    |
+--------------------------------------------+
|     Type        |        Echo ID           |  Control Header
+--------------------------------------------+
|       Transmit / Echo Timestamp [31:0]     |
+--------------------------------------------+
|  Tag  |Error State| Supported path count   |  Echo Packet
+--------------------------------------------+  Contents
|  Reserved        |   Active Port Set       |
+--------------------------------------------+
|           Echo payload                     |
+--------------------------------------------+
|       Echo payload - as needed             |
+--------------------------------------------+
```

| Field | Description |
|-------|-------------|
| Type | 0 = echo request; 1 = echo response |
| Echo ID | Allows sender to match response to request |
| Transmit/Echo Timestamp | TX timestamp in request; echoed in response |
| Tag | Tag field for context |
| Error State | Zero in request; populated in response using Table 8.6 codes |
| Supported path count | Set to number of supported TX paths on sender side; updated in ping response to reflect supported RX paths |
| Active Port Set | Ready port status bitfield |
| Echo payload | Variable length; echoed verbatim in response |

**Echo Response Error State Codes (Table 8.6):**

| Error State | Description |
|-------------|-------------|
| 0 | No reported error |
| 1 | QP not present / unknown |
| 2 | Reserved |
| 3 | Tag not associated with QP |
| 4 | Source address not associated with QP |
| 5 | Destination address not associated with path |
| 6 | Path ID unsupported / too large |

---

### 1.11 Atomic Extended Transport Header (AtomicETH)

**Implementation Note:** Atomic operations (FetchAdd 0xD4, CmpSwap 0xD5, Atomic Ack 0xD2) are **NOT IMPLEMENTED**. Atomic Request packets will generate NAK-Invalid-Operation. See `docs/07-feature-status.md` for details.

For FetchAdd and CmpSwap atomic operations. Opcodes 0xd4-0xd7.

```
 31      24 23    21 20    16 15             0
+---------+--------+--------+----------------+
| Code:0xd4-7|Rsvd |  Ver   |    PathID      |  Base Header
+--------------------------------------------+
|              Destination QP                |
+--------------------------------------------+
|               Source QP                    |
+--------------------------------------------+
|    Flow Sequence Number (FSN) [31:16]      |
|    Flow Sequence Number Clear (UNA) [15:0] |  METH
+--------------------------------------------+
|  Tag  |A|R|T| Rsvd  |     POSN: 0         |
+--------------------------------------------+
|   CSN: undefined    |     MSN [15:0]       |
+--------------------------------------------+
|            Rate Hints [31:0]               |
+--------------------------------------------+
|         Transmit Timestamp [31:0]          |
+--------------------------------------------+
|         Virtual Address [63:32]            |  AtomicETH
+--------------------------------------------+
|         Virtual Address [31:0]             |
+--------------------------------------------+
|              R_Key [31:0]                  |
+--------------------------------------------+
|       Swap (or Add) Data [63:32]           |
+--------------------------------------------+
|       Swap (or Add) Data [31:0]            |
+--------------------------------------------+
|          Compare Data [63:32]              |
+--------------------------------------------+
|          Compare Data [31:0]               |
+--------------------------------------------+
```

**Notes:**
- The atomic is a **single-packet message**: POSN is always zero.
- CSN is undefined because there is no corresponding receive WQE.
- Atomic requests with nonzero POSN must be discarded; a NAK-Invalid Request may be sent.
- Virtual Address must be aligned to 8 bytes.

---

### 1.12 Atomic Ack Extended Transport Header (AtomicAckETH)

**Implementation Note:** This header is reserved but unused. Atomic operations are **NOT IMPLEMENTED**. See `docs/07-feature-status.md`.

Response to atomic operation. Opcode 0xd2.

```
 31      24 23    21 20    16 15             0
+---------+--------+--------+----------------+
| Code:0xd2|  Rsvd |  Ver   |    PathID      |  Base Header
+--------------------------------------------+
|              Destination QP                |
+--------------------------------------------+
|               Source QP                    |
+--------------------------------------------+
|    Flow Sequence Number (FSN) [31:16]      |
|    Flow Sequence Number Clear (UNA) [15:0] |  METH
+--------------------------------------------+
|  Tag  |A|R|T| Rsvd  |     POSN: 0         |
+--------------------------------------------+
|   CSN: undefined    |     MSN [15:0]       |
+--------------------------------------------+
|            Rate Hints [31:0]               |
+--------------------------------------------+
|         Transmit Timestamp [31:0]          |
+--------------------------------------------+
|      Original Remote Data [63:32]          |  AtomicAckETH
+--------------------------------------------+
|      Original Remote Data [31:0]           |
+--------------------------------------------+
```

| Field | Description |
|-------|-------------|
| Original Remote Data | For FetchAdd: the fetched value before addition. For CmpSwap: the value before the comparison (may or may not have matched). |

**Notes:**
- The atomic ack is a single-packet message (POSN always zero).
- Carries the MSN of the original atomic request.
- The "Atomic Ack" does NOT acknowledge data. The FSN associated with the atomic operation will be separately acknowledged using a SAETH Ack packet.

---

## 2. Opcode Table

Meta-RoCE uses transport type bits [7:5] = `110`. Full opcode table (Table 8.1):

| Opcode [7:5] | Opcode [4:0] | Hex | Description | Additional Headers |
|---------|---------|-----|-------------|-------------------|
| 000 | xxxxx | — | RoCEv2 RC (not Meta-RoCE) | — |
| 100 | xxxxx | — | RoCEv2 UD (not Meta-RoCE) | — |
| 110 | 00000 | 0xC0 | Send | METH, Payload |
| 110 | 00001 | 0xC1 | Send with Immediate Present | METH, ImmDt, Payload |
| 110 | 00010 | 0xC2 | RDMA Write with Immediate Present | METH, RETH, ImmDt, Payload |
| 110 | 00110 | 0xC6 | RDMA Write | METH, RETH, Payload |
| 110 | 00111 | 0xC7 | RDMA Write with Immediate | METH, RETH, Payload |
| 110 | 01100 | 0xCC | RDMA Read Request | METH, RETH |
| 110 | 01101 | 0xCD | RDMA Read Request with Immediate Present | METH, RETH, ImmDt |
| 110 | 01111 | 0xCF | RDMA Read Response | METH, Payload |
| 110 | 10000 | 0xD0 | RNR-Cancel, Receiver Is Ready | RNR-Cancel header |
| 110 | 10001 | 0xD1 | Selective Ack | SAETH |
| 110 | 10010 | 0xD2 | Atomic Ack (Response) | METH, AtomicAckETH |
| 110 | 10100 | 0xD4 | FetchAdd | METH, AtomicETH |
| 110 | 10101 | 0xD5 | CmpSwap | METH, AtomicETH |
| 110 | 1011x | 0xD6-7 | Reserved for Atomics | METH, AtomicETH |
| 110 | 11110 | 0xDE | Reliable Control | METH, Control, Payload |
| 110 | 11111 | 0xDF | Unreliable Control | Control, Payload |

**Notes:**
- 14 of 32 possible opcodes are allocated. Those not in this table are reserved.
- "Immediate Present" opcode indicates the specific packet carries an immediate header.
- Send-with-Immediate-Present appears only on the **last packet** of a send-with-immediate operation.
- Write-with-Immediate opcode (0xC7) is used on **all packets except the last** of a write-with-immediate message; the last uses "RDMA Write with Immediate Present" (0xC2).
- The "Write with Immediate Present" opcode is used by the receiver to match MSN and CSN to a known receive WQE.
- Read/ImmDt (0xCD) may not be supported.
- Reliable Control (0xDE) may not be supported.
- 0xC2 = Write with Immediate Present opcode; 0xC7 = Write with Immediate opcode.

**Zero-byte payload table (Table 8.2):**

| Opcode | Zero Data | Notes |
|--------|-----------|-------|
| 110 00000 — Send | Permitted | |
| 110 00001 — Send with Immediate Present | Permitted | |
| 110 00010 — RDMA Write with Immediate Present | Permitted | |
| 110 00110 — RDMA Write | **Forbidden** | NAK-Invalid Request or drop silently |
| 110 00111 — RDMA Write with Immediate | **Forbidden** | NAK-Invalid Request or drop silently |
| 110 01100 — RDMA Read Request | Not applicable (fixed size request) | |
| 110 01101 — RDMA Read Request with ImmDt | Not applicable (fixed size request) | |
| 110 01111 — RDMA Read Response | Permitted | A read request of length zero confirms flush of prior writes |
| 110 10000 — RNR-Cancel | Not applicable | |
| 110 10001 — Selective Ack | Not applicable | |
| 110 10010 — Atomic Ack | Not applicable (fixed size) | |
| 110 10100 — FetchAdd | Not applicable (fixed size) | |
| 110 10101 — CmpSwap | Not applicable (fixed size) | |
| 110 1011x — Reserved Atomics | Not applicable (fixed size) | |
| 110 11110 — Reliable Control | Permitted (message may be in header) | |
| 110 11111 — Unreliable Control | Permitted | |

---

## 3. Packet Formats by Operation Type

### 3.1 Full Packet Stack: Send

```
[ Ethernet | IPv6 | UDP (dport=2766) | BTH | METH | Payload | mCRC | FCS ]
```

- BTH Opcode: `110 00000` (Send) for all non-last-immediate packets
- BTH Opcode: `110 00001` (Send with Immediate Present) for last packet when immediate data present
- METH: FSN, UNA, Tag, A/R/T, POSN, CSN, MSN, RateHints, Timestamp
- Payload: Application data (0 bytes permitted)
- mCRC: 32-bit CRC over Meta-RoCE headers + payload

### 3.2 Full Packet Stack: RDMA Write

```
All packets except last (write-with-immediate case):
[ Eth | IP | UDP | BTH(0xC7 or 0xC6) | METH | RETH | Payload | mCRC | FCS ]

Last packet (write-with-immediate):
[ Eth | IP | UDP | BTH(0xC2) | METH | RETH | ImmDt | Payload | mCRC | FCS ]

Plain write (all packets):
[ Eth | IP | UDP | BTH(0xC6) | METH | RETH | Payload | mCRC | FCS ]
```

- RETH present in every packet of the write message (address, R_Key, length are identical across all packets).
- Payload: Zero bytes forbidden for plain write; permitted for write-with-immediate.
- CSN field in METH is unused/undefined for Write operations.

### 3.3 Full Packet Stack: RDMA Read Request

```
[ Eth | IP | UDP | BTH(0xCC) | METH | RETH | mCRC | FCS ]
```

- Single packet (request only; no payload).
- RETH specifies the remote memory region to read and length.
- POSN is 0 (single-packet message).

### 3.4 Full Packet Stack: RDMA Read Response

```
[ Eth | IP | UDP | BTH(0xCF) | METH | Payload | mCRC | FCS ]
```

- Multiple packets if large; POSN indicates offset within response data.
- MSN in response carries the MSN of the original read request.
- No RETH in read response.

### 3.5 Full Packet Stack: Atomic (FetchAdd / CmpSwap)

```
Request:
[ Eth | IP | UDP | BTH(0xD4 or 0xD5) | METH | AtomicETH | mCRC | FCS ]

Response:
[ Eth | IP | UDP | BTH(0xD2) | METH | AtomicAckETH | mCRC | FCS ]
```

- Single-packet in both directions.
- POSN = 0 always.
- AtomicETH contains: virtual address, R_Key, Swap/Add data, Compare data.
- AtomicAckETH contains: original remote data (prior value).
- Separate SAETH ACK still required for FSN acknowledgment.

### 3.6 Full Packet Stack: Selective ACK

```
In-order (no bitset):
[ Eth | IP | UDP | BTH(0xD1) | SAETH(20 bytes) | mCRC | FCS ]

Out-of-order (FSN bitset present):
[ Eth | IP | UDP | BTH(0xD1) | SAETH(20 bytes) | FSN Bitvec(32 bytes) | mCRC | FCS ]

BRNR (FSN + RNR bitsets present):
[ Eth | IP | UDP | BTH(0xD1) | SAETH(20 bytes) | FSN Bitvec(32 bytes) | RNR Bitvec(32 bytes) | mCRC | FCS ]
```

- Minimum ACK: 20 bytes (SAETH base, no bit vectors).
- Maximum ACK: 20 + 32 + 32 = 84 bytes (with both FSN and RNR bit vectors).
- ACKs are sent on a different traffic class from data packets (higher priority expected).

### 3.7 Full Packet Stack: RNR-Cancel

```
[ Eth | IP | UDP | BTH(0xD0) | RNR-Cancel Header | mCRC | FCS ]
```

- 4 words of RNR-Cancel header after Base Header.
- Sent unreliably.

---

## 4. Sequence Number System

### 4.1 Four Sequence Numbers and Their Scopes

```
Scope hierarchy:
  QP+Tag  --->  MSN  (Message Sequence Number)
  QP+Tag  --->  CSN  (Completion Sequence Number)
  Message --->  POSN (Packet Offset Sequence Number)
  QP+Path --->  FSN  (Flow Sequence Number)
```

| Sequence Number | Scope | Increments On | Start Value | Can Wrap | Width |
|----------------|-------|--------------|------------|----------|-------|
| MSN | Per QP+Tag | Every WQE posted at initiator | Negotiated at QP setup | Yes | 16 bits |
| CSN | Per QP+Tag | Every Receive-WQE-consuming WQE posted at responder | Negotiated at QP setup | Yes | 16 bits |
| POSN | Per message | Every packet within a message | 0 (per message) | No | 16 bits |
| FSN | Per QP+Path | Every packet sent on that path | 0 | Yes | 16 bits |

**Key binding:** A data packet identified by POSN within the context of (QP, Tag, MSN) is bound to the FSN scoped within (QP, Path). This binding is **immutable** (except in cases of RNR processing).

**CDMSN:** The Cumulative Responder Delivered MSN is the highest MSN of in-order received and delivered messages. Tracked per QP+Tag. Carried in ACKs. Initial value is one less than the negotiated initial MSN.

**No QP-level PSN:** In contrast to RoCE, there is no QP-level packet sequence number. Packets within messages are not identified as first/middle/last.

### 4.2 POSN Constraints

- POSN starts at zero in every message.
- Indexes in payload-sized increments (each packet must be full MTU except possibly the last).
- Cannot wrap. Maximum message = 2^28 bytes = 256 MB (with 16-bit POSN and 4096-byte MTU).
- Larger messages are not supported and must be split.

### 4.3 FSN UNA (Clear) Field

- Data packets contain `snd.una` in the FSN Clear (UNA) field.
- `snd.una` = the next contiguously acknowledged FSN from the sender's perspective.
- Unacknowledged FSNs can be skipped (used when a message was stopped due to RNR and will be transmitted later with different FSNs).
- When the receiver processes a data packet carrying UNA=N, it frees per-FSN state for FSN 0 through N-1 and advances CumulativeFSN to N-1.

---

## 5. Reliable Delivery Mechanisms

### 5.1 mCRC Bit Error Detection

- CRC-32, same polynomial as Ethernet CRC.
- Pre-inverted (starts with value -1) and post-inverted.
- Covers from the beginning of the Meta-RoCE header (Base Header) to the end of data payload.
- Does **not** include outer Ethernet/IP/UDP headers.
- Appended at end of UDP payload.
- A frame received with an invalid mCRC **must be discarded**.
- mCRC is omitted when carried by PSP encapsulation (redundant).
- mCRC is **required** when carried by ESUN encapsulation.

### 5.2 Acknowledgment Generation

**When transmitter sets the Ack Request (A) bit:**

The transmitter should set the A (flush ack) bit on every packet that is:
1. At the end of a window of transmitted packets (when sending this packet leaves no available window space).
2. At the end of a batch of transmitted packets (if sending 4 packets at a time per path, the 4th should request an ack, unless more will be sent very soon).
3. Whenever sending a smaller-than-MTU packet (immediate ACK may enable eager completion).
4. When the per-path window is less than a configurable number (typically 4) of packets.
5. On all retransmissions (in addition to requesting ack, retransmissions are marked within the data header and the encapsulating IPv6 header).
6. On the first packet sent on each path during fast-start.
7. When there are no more packets to send.

**When receiver must send an acknowledgment:**
1. After receipt and delivery to memory of a packet carrying the A (ack request) bit.
2. After receipt and delivery to memory of out-of-order data (if FSN 2 is received when FSN 1 has not been, an eager ACK expressing the hole allows immediate retransmission).
3. After a change in congestion state (if a CE-marked packet is received after one that was not).
4. On receipt of out-of-window data (e.g., if FSN 2 has been cumulatively ACKed and FSN 400 is received, the ACK sent in response restates the receiver's state).

**"Send" in this context means preparing an ACK that will either be transmitted promptly or superseded by a subsequent ACK.** Under load or with small packets, multiple conditions may occur before a single ACK can be transmitted; a single ACK is permitted to satisfy multiple pending conditions.

### 5.3 Packet Trackers

**Transmitter Packet Tracker, per path:**
- `snd.nxt[p]`: Next scheduled FSN (monotonically increasing).
- `snd.una[p]`: Next contiguously ACKed FSN (advanced based on ACKs received; may advance from out-of-order ACKs in RNR handling).
- `snd.cur[p]`: Next retransmission cursor (to prevent repeated retransmission on duplicate SACK; updated to at least snd.una when in-order data ACKed; incremented to cover data retransmitted for a gap; reset to snd.una on RTO expiration).
- `snd.inflate[p]`: Number of FSNs selectively ACKed in the window (snd.una to snd.nxt).

**Receiver Packet Tracker, per path:**
- Tracks the values described in the ACK contents section (CumulativeFSN, SelAckBitVector, MaxFSN).

**Window:**
- The "window" for path p = snd.nxt[p] - snd.una[p].
- Sender must track the delivery status of each FSN within this window so unacknowledged packets can be retransmitted.
- Maximum window size should accommodate bandwidth-delay product (BDP).

### 5.4 RTT Measurement

Every data packet carries a Transmit Timestamp (`T_send`). When a packet triggers an ACK, the receiver echoes this timestamp in the Echo Timestamp field of the ACK. The sender computes:

```
RTT_meas = T_curr - T_send
```

If packets are received out of order, the timestamp most recently received on a path is echoed. This means:
- The first ACK echoes T_2 (the newer packet), measuring a short RTT.
- The second ACK echoes T_1 (the older packet), measuring a longer RTT.

Two smoothed RTT estimates maintained:

```
RTT[p]          = (1 - alpha_p)  * RTT[p]          + alpha_p  * RTT_meas
RateWeightedRTT = (1 - alpha_qp) * RateWeightedRTT + alpha_qp * RTT_meas
```

Where `alpha_p` = per-path smoothing factor, `alpha_qp` = per-QP smoothing factor (both may be negative powers of 2 for implementation simplicity).

### 5.5 RTO (Retransmission Timeout) Computation

```
mdev = (1 - beta) * mdev + beta * |RTT_meas - RTT[p]|
RTO  = MIN(upper, MAX(lower, RTT[p] + 4 * mdev + rho * RTT_meas))
```

Where:
- `lower`: configurable minimum RTO lower bound (must not retransmit by timeout before this time). Typical: 5-100 μs.
- `upper`: configurable maximum RTO upper bound. Typical: 100ms-1s.
- `rho` (ρ): configurable additive offset accounting for processing delays not captured by RTT measurement.
- `mdev`: mean deviation; adjusts for cases of high RTT uncertainty.
- Per-path RTO tracking is recommended but per-QP `RateWeightedRTT` and mean deviation may be used instead.
- The timer applies **per path** regardless of whether RTT estimate is per-path or per-QP.
- One timer per path, not one per packet; reset every time a new packet is sent on that path.

**When `snd.nxt > snd.una` and RTO time has elapsed since last transmission:**
- Retransmission should occur.
- On RTO expiration: reset `snd.cur` to `snd.una`, change path entropy value, retransmit.

**RTO retransmission count:** Configuration must allow:
- A single packet (first, snd.una, or last, snd.nxt-1)
- All unacknowledged packets
- N packets
- Retransmissions by timeout must not be prevented by congestion window checks.

### 5.6 SACK-Based Retransmission (Packet Loss Detection by Out-of-Order Receipt)

When a receiver detects an out-of-order FSN (gap in the FSN space), it sends an eager ACK expressing the hole. The sender can retransmit the missing packet.

**Retransmission cursor (`snd.cur`):**
- Purpose: Prevent repeated retransmission in response to duplicate selective ACKs.
- `snd.cur` is updated to at least `snd.una` when in-order data is ACKed.
- Incremented to cover data retransmitted to fill a gap in SACK.
- A gap will not solicit additional retransmissions once `snd.cur` advances past the gap position.
- The RTO timer is reset by any transmission, including retransmission.

**SACK retransmission cursor advancement (Figure 4.8 — example):**

```
Initial state: snd.una=0, snd.cur=0, snd.nxt=10

After ACK(CFSN=1):                 una=2, cur=2, nxt=12 → transmit 10,11
After ACK(CFSN=1, bits=10):        una=2, cur=3, nxt=12 → retransmit 2
After ACK(CFSN=1, bits=110):       una=2, cur=3, nxt=13 → transmit 12
After ACK(CFSN=1, bits=100110):    una=2, cur=6, nxt=14 → retransmit 5, transmit 13
After ACK(CFSN=1, bits=1100110):   una=2, cur=7, nxt=14 → retransmit 6
After ACK(CFSN=4, bits=11100):     una=5, cur=7, nxt=16 → transmit 14,15
```

**Two modes for in-network packet reordering tolerance:**
1. Disabling SACK-based packet loss detection (ACK only used to prevent timeout-based retransmission of received data).
2. Permitting sack-based retransmission and advancement of `snd.cur` only when `snd.cur < MaxFSN - configurable_fraction_of_path_window`.

### 5.7 Retransmission Marking

All retransmissions must be sent with:
- **R bit** set in the METH data header (retransmission marker).
- **T bit** set in METH if the retransmission was triggered by timeout (not SACK).
- The high bit of the IPv6 hop count field optionally set (for SACK-based retransmissions not changing entropy, typically; the high bit enables in-network monitoring by switches without parsing Meta-RoCE header).

### 5.8 Eager Tail Retransmission (Optimization)

When tail loss is suspected (connection idle for interval RTT < idle < RTO) and there is no additional data to send, a transmitter may eagerly retransmit the last packet. This is an optional optimization.

### 5.9 Alternate Path Retransmission (Optimization)

On RTO:
1. **Change entropy value:** The sender should change the UDP source port (entropy) of the current path before retransmitting, so retransmitted packets are directed differently through the network.
2. **Change output port on subsequent RTO:** On a multi-port NIC, the sender may reassign the path to a different output port if the current port pair appears unresponsive after a second or subsequent RTO.

Rules:
- Retransmission must carry the **same path ID and FSN**.
- The entropy value (UDP source port) may change.
- Source and destination addresses in the encapsulating header may change to reflect a new port pair.

---

## 6. Congestion Control

### 6.1 Baseline Congestion Control

**Required.** Sender-driven, window-based AIMD protocol responding to ECN marks and packet loss.

**Window hierarchy:**
- QWND (QP-Level Window) = Σ PWND[p] — limits total outstanding packets on entire QP.
- PWND[p] (Per-Path Window) — limits outstanding packets on path p.

**Available window formula:**
```
AWND[p] = PWND[p] + snd.inflate[p] - (snd.nxt[p] - snd.una[p])
AWND.QP = Σ_p AWND[p]
```

A path is available for scheduling when `AWND[p] > 0`. A QP is available for scheduling when `AWND.QP > 0`.

**Baseline CC Algorithm (mandatory):**

```
On ACK of packet on path p that did NOT experience congestion:
  if (QWND < QWND_max) AND (PWND[p] < PWND_max) AND path was window-limited:
    QWND = min(QWND + min(epsilon, QWND)/QWND, QWND_max)
    increment one PWND[p] to reflect integer QWND change

On ACK of packet that DID experience congestion (ECN CE mark):
  QWND = max(QWND - beta * QWND, QWND_min)
  decrement the same PWND[p] that was congested

On detection of loss of N packets:
  QWND = max(QWND - lambda * N, QWND_min)
```

**Baseline CC Parameters (Table 6.1):**

| Parameter | Default | Min | Max | Description |
|-----------|---------|-----|-----|-------------|
| ε (epsilon) | 1 | 1* | 100 | Per-uncongested-packet fractional window increase |
| β (beta) | 1/2 | 1/8† | 1 | Per-congested-packet window reduction factor |
| λ (lambda) | 1 | 1/8† | 1 | Per-lost-packet window reduction factor |
| fast_start_burst | 4 | 1 | 100 | Packets to send in a burst per path in fast start |

*Advanced/Programmable CC may set ε to zero.
†Advanced/Programmable CC may set to very small fraction (large bit shift).

**PWND[p] update rules:**
- On ACK from uncongested path p (when QWND < QWND_max and PWND[p] < PWND_max): a path may claim the window increment if the fractional QWND increase makes QWND's whole number portion increment AND:
  1. A path being bootstrapped should claim the new path window (Section 7.4).
  2. Default: the path that increments the fractional QWND above integer QWND claims the increase.
  3. Required (but may be disabled): a path may be ineligible to claim the increase if its measured RTT is higher than the known smoothed RTT — a different, less loaded path should claim the increment.
- On decrement of QWND due to congestion or loss: decrease the specific PWND[p] by the same amount. If that PWND reaches zero, the path is deactivated (Section 7.4).

**Additive behavior summary:**
- Full QWND ACKed without congestion: QWND increases additively by ε.
- Full QWND ACKed, all congested: QWND decreases multiplicatively by factor β (comparable to TCP's multiplicative decrease, applied incrementally per-ack).
- Parameters ε=1, β=1/2, λ=1 are reasonable starting points.

### 6.2 Fast Start

Fast Start balances exploring additional paths against having multiple packets on each path when transmitting data at the beginning of an operation, before acknowledgments have been received.

**Algorithm:**

```
ENTRY:
  When Send, RDMA Write, or RDMA Read Response is pushed onto the
  send queue on an idle QP, enter fast start mode.

INITIAL STATE:
  All PWND[p] and QWND are set to zero.

WINDOW ADJUSTMENT:
  Increment PWND[p] and QWND values as packets are sent (contrast
  with baseline where increments occur on ACK receipt). The QP is
  permitted to transmit data as if the available window is QWND_max,
  until the exit condition below.

PATH SELECTION (example — round robin):
  A round robin counter of paths can advance if the current PWND
  is greater than fast_start_burst.
  (See also Figures 6.2, 6.3, 6.4 for recommended packet ordering.)

EXIT fast start mode on any of:
  - Receiving an ACK on any path while there is pending data to send.
  - Receiving an ACK indicating congestion (nonzero CNP field in ack
    indicating data was ECN marked).
  - When QWND >= QWND_max.
  - After an estimated RTT has elapsed since the beginning of fast
    start, while there is pending data to send.

UNUSED AFTER FAST START:
  Paths not visited in fast start with zero PWND[p] will not be
  used until QWND grows to a value suitable for adding a new path
  (Section 7.4).

REENTRY:
  A QP is not required to re-enter fast start when idle.
  Optionally may re-enter fast start after idle for fast_start_idle_interval (ms).
```

**Recommended fast start transmission order (8 paths, burst=4):**

```
Path:  P0  P1  P2  P3  P4  P5  P6  P7
FSN-0:  0   4   8  12  16  20  24  28
FSN-1:  1   5   9  13  17  21  25  29
FSN-2:  2   6  10  14  18  22  26  30
FSN-3:  3   7  11  15  19  23  27  31
FSN-4: 32  33  34  35  36  37  38  39
FSN-5: 40  41
```

### 6.3 Advanced/Programmable Congestion Control

**Optional.** Programmable logic can replace or supplement baseline CC.

**Constraints:**
- Must maintain both QWND and PWND[p] for all QPs and paths.
- Must maintain the invariant: QWND = Σ_p PWND[p].
- Should implement a scheme similar to Section 6.1.2 for QWND updates.
- PWND[p] serves as a load-balancing mechanism.
- Must NOT run an independent CC protocol per path.

**Signals available to Advanced CC (Section 6.2.2):**

QP-Level:
1. QWND (full packet value; fractional optional)
2. AWND.QP or (QWND - AWND.QP) (data in flight)
3. MINRTT.QP (minimum observed RTT; may be cleared on read or after idle)
4. SRTT.QP (smoothed RTT, per-QP)
5. MDEV.QP (averaged difference between measured RTT and SRTT.QP)
6. Cumulative packets delivered CE since last evaluation (CNP counts in multiple ACKs)
7. Cumulative packets delivered since last evaluation
8. Approximate count of remaining packets to be sent on WQEs
9. Time of last advanced CC evaluation
10. Retransmission count
11. Timeout retransmission count
12. QWND_max (from TargetRate) or raw TargetRate field

Path-Level:
1. PWND[p]
2. AWND[p] or (PWND[p] - AWND[p])
3. SRTT[p] (smoothed RTT per path)
4. MDEV[p]
5. Cumulative delivered CE since last evaluation
6. Cumulative delivered since last evaluation
7. Inbound TTL (for delay-based algorithms)
8. Retransmission count
9. Timeout retransmission count

**Advanced CC may implement:**
- TCP Cubic: QWND = 0.4 × (T - sqrt_cube(0.3 × QWND_congestion / 0.4))^3 + QWND_congestion
- TCP Hybla: sets ε to scale with RTT
- Swift: delay-based; target delay based on hop count

### 6.4 Receiver Driven Rate Limiting (RCN)

The receiver computes a TargetRate representing a fair-share bitrate:

```
TargetRate = Total Link Rate (Gbps) / Estimated Concurrent Senders + Target Rate Offset
```

**Estimated Concurrent Senders signals (most-to-least precise):**
1. Number of QPs where most recently received rate hints field is non-zero AND a WQE is active (receiving some but not all data)
2. Number of QPs actively receiving data on any opcode (with active receive WQE or virtual WQE)
3. Number of QPs that have RECV WQEs posted

**Converting TargetRate to QWND_max:**

```
QWND_max = max(QWND_min, gamma * TargetRate * (RateWeightedRTT + omega))
```

Where:
- `gamma` (γ): ≥1; proportional factor for looser limit, reducing RCN influence. Recommended ≤2, likely best at 1.0.
- `omega` (ω): ≥0; fixed headroom in units of delay (NIC-local, e.g., DMA delays).
- `RateWeightedRTT`: Measured by sampling RTT on each path at frequency of every M packets and averaging at QP level.

**Reduction to target rate (Figure 6.5 — four zones):**

```
Protected path: (QWND > p * PWND_floor AND PWND[p] <= PWND_floor)
  → path p may not have PWND reduced further by RCN.

Waiting phase: (QWND > 2 * QWND_max)
  → reduce QWND by one packet per acknowledged packet.
  → no new packets will be sent.

Rate-halving phase: (2 * QWND_max > QWND > QWND_max)
  → reduce QWND by one half packet per acknowledged packet.
  → one new packet sent for every two packets acknowledged.

Normal: (QWND_max >= QWND)
  → no reduction necessary.
```

**PWND_floor:** Configures a minimum PWND for each path below which RCN may not reduce. Default approach: allow high-numbered paths to be reduced to smaller/zero PWND to accomplish reduction while protecting low-numbered paths.

**Interaction with ECN Marking:**
- When `QWND > QWND_max` and ECN marks are signaling congestion, both are active. When in rate-halving phase, an ACK for two packets causes only one packet reduction (not one for rate-halving and another for ECN marks).
- When `QWND ≤ QWND_max`, further ECN-based reductions apply normally.

---

## 7. Ordering

### 7.1 Completion Ordering Modes

Meta-RoCE supports two modes for completion ordering at both sender and receiver:

**Ordered Completion Mode (default):**
Maintains "queue pair" ordering: the first message with a WQE is the first message to complete. Completions depend on the order in which message packets are delivered (not received).

| Operation | Has RWQE | Completes at responder when |
|-----------|----------|----------------------------|
| Send | Yes | All data delivered; all prior messages complete |
| Write | No | All data delivered |
| Write/imm | Yes | All data delivered; all prior messages complete |
| Read | No | All data acknowledged by initiator |
| Read/imm | Yes | All data acknowledged by initiator; all prior messages complete |
| Atomic | No | Executed and is complete once all prior messages are complete |

- Ordered completion mode does not order **writes** to memory; polling the last address of a write is never permitted as a means to infer that any other information has also been written or operations have been completed.

**Unordered Completion Mode (optional):**
Completions may occur in the order data is received or acknowledged. An explicit fence is required to enforce ordering. Allows eager-as-possible pipelining of chunked operations.

**Completion Fence (optional per WQE):**
A per-WQE bit that ensures this specific WQE is completed only when all prior WQEs in the queue have completed. Applies to both initiator (WQE) and responder (RWQE).

### 7.2 In-Protocol Message Sequencing

**MSN and CSN carried per packet:**

- MSN: unique identifier for each message in QP+Tag order. Assigned by initiator.
- CSN: completion sequence number. Reflects order in which WQEs should have been posted at the receiver. Meaningful only for WQEs with a corresponding receive WQE (Send and Write/imm). Undefined/ignored for Write messages.

**Scope:**
- In a QP exclusively using SEND/RECV: MSN always equals CSN.
- In a QP exclusively using Write+Atomics: CSN is undefined and should be ignored.

**CDMSN:** Updated as in-sequence messages are delivered and optionally completed at the responder. Allows the initiator to determine that a message has been completed at the remote endpoint. Initial value = negotiated initial MSN minus 1.

---

## 8. Error Handling

### 8.1 Retriable Errors

| Error Type | Description | Recovery |
|-----------|-------------|----------|
| FSN retry | A packet has been lost; will be retransmitted. Retransmission may use different entropy or port. All errors leading to FSN retries must be counted. | Retransmit |
| Message retry | Non-fatal condition (e.g., RNR); message must be paused and restarted. Where tags supported, retransmission state held with the path is reclaimed. | Pause and restart |
| Path entropy change | Successful delivery through a given ECMP path is questionable; sender changes entropy value to attempt different path. Must be counted. | Change UDP source port |
| Local port fail-over | Multiple ports: a port is allowed to fail without severing the overall QP. | Update Active Port Set; reassign paths |
| Remote port fail-over | Failed remote port detected via Active Port Set or unsuccessful path entropy changes. | Reassign paths to working port pairs |

### 8.2 Recoverable Errors (Sent as NAKs, QP Continues)

| Error | Response |
|-------|----------|
| Invalid Path ID | (preferred) Allocate resources and accept traffic. (not preferred) Discard and send NAK with unsupported status code. |
| Invalid Tag | Send BRNR to indicate message not accepted, but future progress on QP is allowed. If tag support absent: send NAK with Operational Error. |
| Invalid or not cached QP | Send HRNR and notify driver. |
| Source QP mismatch | Silently discard and count. |
| QP not in RTR or RTS state | Send rate-limited NAK with Invalid Request code. |

### 8.3 Message-Fatal Errors

Errors that cannot be recovered; QP placed in error state.

| Error Class | Description |
|-------------|-------------|
| Reliability layer / connectivity failure | Repeated path entropy changes or port fail-overs have failed to reestablish communication. |
| End-to-end message failure | Unrecoverable error condition (excessive RNRs, memory protection errors, etc.) |
| SQ error | All SQEs remaining on SQ must be completed in error; QP placed in error. |
| RQ error | All RQEs remaining on RQ must be completed in error; QP placed in error. |
| SRQ error | If RQ is private RQ, all RQEs must be completed in error. |
| QP error | SQ placed in Error state; if private RQ, RQ also placed in Error. |
| CQ overflow | Asynchronous error event generated; QP placed in error; CQ placed in error. |

### 8.4 Requester Side Errors (Full Table, Section 5.4)

| Error | Description | Handling |
|-------|-------------|----------|
| FSN not acked. Retry limit not exceeded | Responder detected a missing FSN | Requester may retry |
| FSN not acked. Retry limit exceeded | All retransmission attempts failed | Path Level Failover, else WQE failure |
| Local timeout error. Retry limit not exceeded | No Ack response from Responder within timer | Requester may retry |
| Local timeout error. Retry limit exceeded | All retransmission attempts failed | Path level failover, else WQE error |
| HRNR-Nak retry error. Retry limit not exceeded | Hardware RNR-NAK received | Schedule message for retry after indicated time |
| HRNR-Nak retry error. Retry limit exceeded | HRNR retry limit reached | WQE error |
| BRNR-Nak retry error. Retry limit not exceeded | Buffer RNR-NAK received | Free specific FSNs noted in BRNR-NAK; retry under different FSN |
| BRNR-Nak retry error. Retry limit exceeded | Buffer RNR retry limit reached | WQE error |
| Path level timeout exceeded. Port migration limit not exceeded | No forward progress on a path | Path level failure |
| Path level timeout exceeded. Port migration limit exceeded | No forward progress; entropy changes failed | Port level failover |
| WQE timeout exceeded | WQE execution took longer than max configured time | WQE failure |
| Unsupported Opcode | Responder detected defined but unimplemented opcode | WQE failure |
| Local Memory Protection Error | L_key error or other local memory issue | WQE error |
| R_Key error | Responder detected R_Key error | WQE error |
| Remote Operation Error | Other errors detected by Responder (NAK) | WQE error |
| Local Operation Error - WQE | Invalid WQE contents (illegal opcode or other) | WQE error |
| Local Operation Error - no valid WQE | Bad QP number in WQE; WQE incoherent | Drop silently |
| Local resource error | Improperly configured local resources | WQE error |
| Remote length error | Remote node reports an invalid request | WQE error |
| Ghost/unexpected ACK | ACK does not match expected sequence number ranges | Drop silently |
| CQ overflow | CQE cannot be posted | CQ error |

### 8.5 Responder Side Errors (Full Table, Section 5.5)

| Error | Description | NAK Syndrome | Handling |
|-------|-------------|--------------|---------|
| FSN gap detected | FSN beyond next expected received | SACK with appropriate bits | No further action |
| FSN out of range | Packet outside window | Drop; schedule ACK | — |
| Hardware resource not ready | HW resources needed but unavailable | HRNR-NAK | No further action |
| Buffer resource not ready (rendezvous available) | Valid request; RWQE missing; rendezvous ok | BRNR-NAK | No further action |
| Buffer resource not ready (no rendezvous) | Valid request; RWQE missing; no rendezvous | Escalate to HRNR-NAK | No further action |
| Unsupported Opcode | Defined but unimplemented opcode | NAK-Invalid Request | QP error |
| Local Memory Protection Error | L_key error | NAK-Operational Error | WQE error |
| R_Key error | R_Key error | NAK-Address Invalid | Message error, no WQE |
| Memory region does not exist | R_Key + address do not exist | NAK-Address Invalid | Message error |
| Memory region not writable | Write to read-only region | NAK-Address Invalid | Message error |
| Memory region not readable | Read to write-only region | NAK-Address Invalid | Message error |
| Remote Operation Error | Catch-all for other responder errors | NAK-Operational Error | WQE error |
| Local Operation Error - WQE | Invalid WQE contents | NAK - Operational error | WQE error |
| Forbidden zero-byte payload | Zero-byte payload on opcode that forbids it | NAK-Invalid Request or drop | No further action |
| Length error | Send/Write POSN out of range of receive buffer | NAK - Invalid Request | WQE error |
| CQ overflow | Cannot post CQE | Ack may still be sent | CQ error |
| Atomic with nonzero POSN | Atomic request received with POSN != 0 | NAK-Invalid Request or drop | No further action |
| Invalid Atomic Request | Misaligned address or unsupported size | Nak - Invalid Request | QP Error |
| Atomic/RDMA Read resources exceeded (QP-limit) | Configured number exceeded | Nak - Invalid Request | QP Error |
| Atomic/RDMA Read resources exceeded (NIC-limit) | NIC-level limit exhausted | Nak - HRNR | Initiator should retransmit |

---

## 9. Multi-Path Protocol

### 9.1 Path Entropy Values

- Each Meta-RoCE path uses a distinct entropy value (UDP source port).
- Recommended: Device-global counter over ephemeral UDP port range 49152-65535 (14 bits of entropy).
- Counter incremented by 1 on path creation or entropy change.
- Top two bits of UDP source port set to one when counter is used; zero = port set to 0xC000.
- Acknowledgment should use the same source port as the data frame it acknowledges (ensuring ack entropy changes with forward entropy changes, addressing faults on both directions).

### 9.2 Path State Machine (Figure 7.2 — sender side)

All paths start in the "Idle" state.

```
States:
  Start/Idle        No unsent data, no pending data.
  FastStartReady    All paths are Collecting or Inactive.
  Inactive          Path chosen but no pending data.
  BootstrapReady    Path activated; window being built.
  Ready             Path active; AWND[p] > 0.
  Finishing         All data sent; waiting for ACKs.
  Collecting        Other paths Finishing; QP exiting fast start.

Transitions (abbreviated):
  Idle → FastStartReady:     Message posted; all paths ready in Fast Start.
  FastStartReady → Ready:    QP exits Fast Start before sending (PWND[p] > 0).
  Idle → Inactive:           Path chosen but QP exits Fast Start before sending.
  Inactive → BootstrapReady: PWND[p] incrementally reaches fast_start_burst.
  BootstrapReady → Ready:    PWND[p] increased past fast_start_burst.
  Ready → Finishing:         No more data; AWND[p] = 0.
  Finishing → Idle:          No unsent data; ack received and snd.una advanced.
  Ready → Inactive:          PWND[p] decremented to zero (congestion/loss).
  Any → Inactive:            RTO fires; AWND[p] = 0; TX AWND[p] > 0 fails.
```

### 9.3 Number of Paths per QP

- Each QP is assigned a maximum number of paths and associated hardware resources at QP initialization.
- The number of active paths within this maximum can change dynamically.
- Paths are scoped to a QP: path ID identifies a flow within that QP; not shared across QPs.
- A limit on transmit paths may be distinct from a limit on receive paths. Invalid: transmit path count on one end greater than receive path count at the other end.

### 9.4 Activating Paths

To activate a path from the inactive pool:

1. **Determine whether to add a path:**
   ```
   average_window * (active_path_count + 1) < QWND
   AND active_path_count < configured_max_path_count
   ```
   `average_window` may be limited to small power of 2 (1-5) to simplify multiplication to a shift.

2. **Choose a path:** Prefer numerically lowest configured available path; or choose arbitrarily from pool. Assign a new entropy value (UDP source port).

3. **Bootstrap path:** Any PWND increments credited to PWND[p_c] until PWND[p_c] reaches `fast_start_burst`.

4. **Promote to fully active:** Reset the state variable remembering that p_c is the chosen path.

5. **Repeat** if no congestion observed: the overall window has increased by the `fast_start_burst` packets required to activate a new path.

### 9.5 In-activating Paths

A path p is necessarily removed from the active set when its PWND[p] is decremented to zero. Returns to "inactive" pool for reuse. Resource may be reclaimed at the transmitter after `snd.una` advances past the last FSN sent; at the receiver after a configurable interval or CumulativeFSN advance.

### 9.6 Multi-Port Interfaces

Meta-RoCE supports up to **16 addressable ports or planes** (in-protocol signaling limit).

**Two topology modes:**
- **Multi-port:** Each port on sender may address one or more ports at the receiver; different paths have different source and destination addresses.
- **Multi-plane:** Each port on sender sends to exactly one port at the receiver; different planes may use same source and destination addresses.

**State required for multi-port:**
1. Local port number to interface (source) address — global to NIC.
2. Remote port number to interface (destination) address — per QP.
3. Local port ready to transmit set — global to NIC (intersection of config + link status).
4. Remote port ready set — per QP, updated from ACKs with debouncing.
5. Topology wiring table — global to NIC; specifies which local ports can reach which remote ports.
6. Remote port enabled set — per QP, to selectively disable certain destination ports.
7. Selected port pair — per path; may store first-choice or nth alternate.

**Failover Algorithm (transmit path):**
1. Extract port pair associated with path.
2. Confirm local port is ready to transmit, remote port is ready and enabled, port pair exists in topology.
3. If all bits set: transmit.
4. Construct reduced wiring topology (zero out connections associated with inactive/disabled ports).
5. Select alternate port pair from reduced wiring topology, preserving working port:
   a. Local port failed, remote working: find another local port.
   b. Remote port failed, local working: find another remote port.
   c. Neither works: pick random index into reduced wiring topology; find first successor = 1.
   d. Each usable alternative should have equal probability of being chosen.

**Port status maintenance:**
- Port marked not-ready on physical layer link-down event.
- Transition to not-ready: accepted immediately; traffic diverted away.
- Transition to ready: accepted only after debounce duration (~5ms) since last transition to not-ready.

**Port status reporting in acknowledgment:**
- Multi-port NIC copies local port status bitset directly into the Active Port Set field of every ACK.
- A set (1) bit means the port is active. A value of 0 in the field indicates no multi-port support or value 0x1 = only first port active.

---

## 10. RNR Data Recovery Protocol

### 10.1 Three Logical States at Receiver

1. **Delivered:** Packet reliably delivered on network and to application. Normal mode.
2. **Network-delivered but not to application (RNR'd):** Packet arrived but dropped at receiver due to lack of resources (missing RWQE). Receiver sends BRNR with RNR bitset.
3. **Lost on network:** Packet lost; receiver sends SACK indicating gap.

### 10.2 RNR State (BRNR Processing)

**When RNR occurs:**
- The ACK carries a **bit set** indicating which FSNs resulted in RNR.
- The CumulativeFSN is "frozen" until the transmitter acknowledges that the FSN sequence numbers will not be delivered, by setting the UNA field in subsequent data packets to a value greater than the RNR'd FSNs.
- CumulativeFSN pointer cannot move past RNR'd FSNs until UNA advances past them.
- FSNs that resulted in RNR are consumed and will not be assigned to new packets until the FSN sequence numbers wrap.

**Actions taken by the transmitter on receiving BRNR:**

1. Walk through the transmit packet state and identify affected (Tag, MSN) pairs.
2. Stop scheduling new traffic on the affected (Tag, MSN) pairs and, at least, subsequent messages on the same Tag identified by a CSN.
3. Start a timer (configurable: exponential backoff or linear backoff).
4. Keep a copy of the RNR bit map received in the ACK. When a packet is either ACKed normally or identified in the RNR bit map, advance the UNA pointer (Flow Sequence Number Clear / UNA) to the next FSN for which an ACK is expected.
5. When BRNR timer expires, send FSN with UNA=N (the next FSN for which ACK is expected), allowing receiver to free per-FSN state for FSN 0 through N-1.

**Receiver actions upon receiving data packet with UNA=N:**
- Free per-FSN state for FSN 0 through N-1.
- Advance CumulativeFSN to N-1 (if delivering FSN N).
- If FSN N itself also triggers RNR: CumulativeFSN stays at N-1 with RNR bit for FSN N.

### 10.3 HRNR Processing

**Implementation Note:** HRNR (Hardware RNR) is **NOT IMPLEMENTED** in this codebase. Only BRNR (Buffer RNR) via software path_tx retransmission is supported. See `docs/07-feature-status.md` and `docs/03-rx-pipeline.md` section 2.7 for details.

**Spec behavior (unimplemented):**
- HRNR: QP is not initialized or not present in necessary cache. Hardware resources unavailable.
- Individual RNR bits would not be meaningful (no QP and path state known).
- No RNR bitset sent with HRNR.
- All messages on **all tags** must wait for QP to be activated.
- Requester notified by driver.

**Current implementation:** BRNR only — receiver detects insufficient RWQE credits, generates BRNR NAK, sender retransmits after rnr_timeout.

---

## 11. Sequence Diagrams for Key Flows

### 11.1 Basic Write Flow (Single Path, No Packet Loss)

```
Initiator                                           Responder
    |                                                   |
    |-- Write MSN:0 POSN:0 FSN:0 PathID:0 UNA:0 ------>|
    |   (METH: Tag=0, A=0, R=0, T=0, CSN=?, Rate, TS)  |
    |   (RETH: addr, rkey, len)                         |
    |                                                   |--> write to memory[0*MTU]
    |-- Write MSN:0 POSN:1 FSN:1 PathID:0 UNA:0 ------>|
    |                                                   |--> write to memory[1*MTU]
    |-- Write MSN:0 POSN:2 FSN:2 PathID:0 UNA:0 ------>|
    |   (A=1 — ack request on last/small packet)        |--> write to memory[2*MTU]
    |<-- ACK CFSN:2 MAX:2 Bits:- CDMSN:0 Rate:Xgbps ---|
    |                                                   |
```

### 11.2 Send Flow with Packet Loss and SACK Retransmission

```
Initiator                                           Responder
    |                                                   |
    |-- Send MSN:0 POSN:0 FSN:0 PathID:0 UNA:0 ------->|
    |-- Send MSN:0 POSN:1 FSN:1 PathID:0 UNA:0 ------->|
    |-- Send MSN:0 POSN:2 FSN:2 PathID:0 UNA:0 -X DROP |  (FSN 2 dropped)
    |-- Send MSN:0 POSN:3 FSN:3 PathID:0 UNA:0 ------->|
    |<-- ACK CFSN:1 MAX:3 Bits:10 -------------------- |  (bit 0 = FSN 3 received)
    |-- Send MSN:0 POSN:4 FSN:4 PathID:0 UNA:0 ------->|
    |<-- ACK CFSN:1 MAX:4 Bits:110 ------------------- |  (FSN 3,4 received; FSN 2 missing)
    |-- Retransmit MSN:0 POSN:2 FSN:2 UNA:0 (R=1) ---->|
    |<-- ACK CFSN:4 MAX:4 Bits:0 --------------------- |  (all in order now)
    |                                                   |
```

### 11.3 RDMA Read Flow

```
Initiator                                           Responder
    |                                                   |
    |-- Read Req MSN:1 POSN:0 FSN:5 PathID:0 ---------->|
    |   (RETH: remote_addr, rkey, length=8192)          |
    |                                                   |--> read from memory
    |<-- Read Resp MSN:1 POSN:0 FSN:10 PathID:0 --------|
    |<-- Read Resp MSN:1 POSN:1 FSN:11 PathID:0 --------|  (A=1 on last)
    |                                                   |
    |-- ACK(PathID:0) CFSN:11 ------------------------>|  (ACK the read response FSNs)
    |                                                   |
```

### 11.4 RNR Flow (BRNR)

```
Initiator                                           Responder
    |                                                   |
    |-- Send MSN:2 POSN:0 FSN:2 UNA:0 ---------------->|
    |                                                   | (No RWQE posted! Tag 2 RNR'd)
    |<-- BRNR(FSN bitset indicating FSN 2 is RNR'd) ----|
    |   (CumulativeFSN frozen at 1)                     |
    |                                                   |
    | [Timer expires]                                   |
    |-- Send MSN:5 POSN:0 FSN:8 UNA:8 ---------------->|  (New data; UNA=8 frees FSN 0-7)
    |                                                   |--> receiver frees FSN 0-7
    |<-- ACK CFSN:8 -----------------------------------|
    |                                                   |
    | [Tag 2 rescheduled with new FSN]                  |
    |-- Send(Tag 2) MSN:2 POSN:0 FSN:9 UNA:9 --------->|
    |                                                   | (RWQE now posted)
    |<-- ACK CFSN:9 CDMSN:2 ---------------------------|
    |                                                   |
```

### 11.5 Multi-Path Fast Start (2 Paths, burst=2)

```
Initiator                               Responder
    |                                       |
    | [Fast Start Entry: QWND=0, PWND[0]=0, PWND[1]=0]
    |-- FSN:0 PathID:0 POSN:0 UNA:0 ------>|  [PWND[0]++ → 1]
    |-- FSN:0 PathID:1 POSN:1 UNA:0 ------>|  [PWND[1]++ → 1]
    |-- FSN:1 PathID:0 POSN:2 UNA:0 ------>|  [PWND[0]++ → 2; fast_start_burst reached]
    |-- FSN:1 PathID:1 POSN:3 UNA:0 (A=1)->|  [PWND[1]++ → 2; fast_start_burst reached]
    |<-- ACK PathID:0 CFSN:1 ------------- |  [Fast Start EXIT; transition to normal CC]
    |                                       |
```

---

## 12. Verbs Library Integration Notes

### 12.1 QP Type

To specify Meta-RoCE QP type when calling `ibv_create_qp()`:
```c
qp_init_attr->qp_type = 0xFF;  // Meta-RoCE Connected Mode
```

### 12.2 Initial CSN/MSN

The message sequence numbers correspond roughly to the RoCE PSN. To configure initial CSN and MSN:
- `sq_psn` configures the local NIC values for sending (initial TX MSN/CSN).
- `rq_psn` configures the values it expects when receiving (initial RX MSN/CSN).
- Both `sq_psn` and `rq_psn` are 32 bits: 16 MSBs represent starting CSN; 16 LSBs represent starting MSN.
- Note: Initial CSN may be limited to 255 (8-bit) due to 24-bit PSN encoding constraints in the verbs interface.

### 12.3 Tags

**Implementation Note:** Tags are **NOT IMPLEMENTED** in this codebase. The Tag field in METH/SAETH headers is always set to 0. See `docs/07-feature-status.md` for details.

**Spec behavior (unimplemented):**
- A QP gets one Tag by default (Tag 0) on creation.
- To create additional Tags: use `ibv_create_qp_ex()` with `IBV_QP_CREATE_SOURCE_QPN` flag set in `init_attr_ex->create_flags` and `init_attr_ex->source_qpn` set to an existing QP number.
- The 8 MSBs of `ibv_qp->qp_num` are used as the Tag number.
- Tags must be created on both endpoints. The Tag number must be the same on both endpoints.
- All Tags must be created before the QP moves to INIT state.
- Tags within a QP share the same destination GID and congestion state.

**Current implementation:** Single stream per QP; applications needing multiple concurrent streams must create multiple QPs.

### 12.4 Multi-Port API

Configure multiple local and remote GIDs via `ibv_modify_qp()`:
- Use `ah_attr.grh.sgid_index` and `ah_attr.port_num` for local network-level addresses.
- Use `ah_attr.grh.dgid` for remote network-level endpoint addresses.
- Repeated invocations with `IBV_QP_AV` flag will **append** (not overwrite) GID entries.
- Alternatively: `ibv_modify_qp_multi_port()` accepts a single structure representing all pairs.
- All port/GID configuration must occur while QP is in INIT state.

**`ibv_modify_qp()` extended semantics:**
- Appending GIDs: `attr->ah_attr.grh.dgid`, `attr->ah_attr.grh.sgid_index`, `attr->ah_attr.port_num` add a GID pair.
- Uniqueness enforcement: each GID pair added only once; duplicate calls ignored.
- GID pools: an SGID can be added to SGID pool (all communicate with all DGIDs); DGID can be added to DGID pool; the QP uses either list of GID pairs OR product of SGID and DGID pool entries.
