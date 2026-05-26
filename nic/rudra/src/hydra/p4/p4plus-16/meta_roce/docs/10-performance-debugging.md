# Performance Debugging

Performance debugging workflow for Meta RoCE RDMA dataplane on Vulcano ASIC.

## Overview

This guide covers debugging RDMA performance issues: low throughput, high latency, or suboptimal bandwidth utilization. It provides a systematic workflow using asicmon and nicctl to identify bottlenecks.

**Key Principle:** Drops and backpressure are ONLY problems if bandwidth is below line rate. At line rate, they indicate healthy flow control.

---

## Prerequisites

**Before debugging:**
1. Traffic must be actively running (ib_write_bw, rdma_bw, perftest, etc.)
2. Know the expected baseline throughput/latency for your workload
3. Identify the target NIC (card UUID, BDF, port number)

**Tools required:**
- `asicmon` — ASIC pipeline monitor
- `nicctl` — NIC control utility
- `lspci` — PCIe verification

---

## Performance Debugging Workflow

### Step 0: Identify Target Card UUID ⚠️ REQUIRED FIRST

**Why:** Each node in a testbed has different card UUIDs at the same BDF. Using the wrong UUID causes assertion failures.

**Single-node or when on the node itself:**
```bash
# Get card UUID for specific BDF
nicctl show card | grep -A1 "06:00.0"

# Or with JSON filtering
nicctl show card --json | jq -r '.cards[] | select(.pcie_bus_device_function=="0000:06:00.0") | .id'
```

**Multi-node testbeds:**
```bash
# Map each node to its card UUID
for node in node1 node2; do
  ssh $node "echo === $node === && nicctl show card | grep -E 'Id|06:00'"
done

# Example output:
# === node1 ===
# 42424650-5232-3534-3830-303136000000    0000:06:00.0
# === node2 ===
# 42424650-5232-3534-3830-303330000000    0000:06:00.0
#                                ^^
#                  Different UUIDs for same BDF!
```

**Store per-node:**
```bash
CARD_UUID_NODE1="42424650-5232-3534-3830-303136000000"
CARD_UUID_NODE2="42424650-5232-3534-3830-303330000000"
```

**Common error if skipped:**
```
pal_reg_rd32w: failed to map pa 0x325530c8
asicmon: sdk/platform/pal/src/ipc/x86_64/reg.c:174: pal_reg_wr32w: Assertion `0' failed.
```

**Fix:** Use the correct card UUID for the specific node you're debugging.

---

### Step 1: Check Wire Bandwidth (Are we at line rate?)

**This is the PRIMARY check.** If at line rate, drops/XOFF are expected flow control.

**1a. Get port speed (baseline):**
```bash
nicctl show port -c $CARD_UUID
```

**Example output:**
```
speed                  : 400G
Operational status     : UP
```

**1b. Check actual wire bandwidth:**

**Option A: asicmon -P (detailed, resets counters - ask user first!):**
```bash
source /etc/profile.d/amd_ainic_user_profile_update.sh
PAL_CARD_UUID=$CARD_UUID asicmon -P | grep -E "PBI_NET_BPS|PBE_NET_BPS"
```

**Example output:**
```
PB_SWITCH
  PBI_NET_BPS  PBI_UD0_BPS  PBI_UD1_BPS 
       416.8G       206.5G       198.8G
  
  PBE_NET_BPS  PBE_UD0_BPS  PBE_UD1_BPS
       405.2G       178.3G       215.4G
```

**Interpretation:**
- `PBI_NET_BPS`: Network ingress bandwidth (wire → ASIC)
- `PBE_NET_BPS`: Network egress bandwidth (ASIC → wire)
- Compare to port speed (400G in this example)

**Option B: vanilla asicmon (safe, cumulative):**
```bash
PAL_CARD_UUID=$CARD_UUID asicmon | grep -E "TX Scheduler|TXDMA|RXDMA"
```

**Decision:**
- **Wire BW ≥ 95% of line rate?** → ✅ **System healthy, STOP HERE**
  - Drops are flow control (window full, spurious PHVs)
  - XOFF is rate matching (PCIe faster than wire)
- **Wire BW < 95% of line rate?** → ❌ **Bottleneck exists, continue to Step 2**

---

### Step 2: Check Stage Backpressure (XOFF)

**Use vanilla asicmon (safe, non-destructive):**
```bash
PAL_CARD_UUID=$CARD_UUID asicmon
```

**Look for stage XOFF:**
```
== UDMA0 ==
 S0: (utl/xff/idl) in=  0/  0/100 out=  3/  0/ 97
 S1: (utl/xff/idl) in= 10/  5/ 85 out= 15/  0/ 85
 S2: (utl/xff/idl) in= 15/  0/ 85 out= 18/  0/ 82
 S3: (utl/xff/idl) in= 20/  0/ 80 out= 25/  0/ 75
 S4: (utl/xff/idl) in= 25/ 10/ 65 out= 30/ 85/ 40
                                          ↑
                                    85% XOFF!
```

**Format:** `(util/xoff/idle)`
- **util**: Percent time stage is busy
- **xoff**: Percent time experiencing backpressure
- **idle**: Percent time stage is idle

**Interpretation:**
- `out xoff > 50%` → Backpressure from downstream stage
- Bottleneck is the **next stage** (downstream from high XOFF)
- XOFF = 100% - DRDY (from asicmon -P)

**Example:**
- S4 has `out xoff = 85%` → S5 is the bottleneck (can't consume from S4)

**If high XOFF found, get detailed breakdown:**
```bash
# Ask user first - resets counters!
PAL_CARD_UUID=$CARD_UUID asicmon -P
```

**Look at bottleneck stage (downstream of high XOFF):**
```
 S SRDY  DRDY  MPU0  MPU1  MPU2  MPU3  MPU4  MPU5  CH0  CH1  RDS  WRS    DHIT   DMISS
S5   25    15    52    44    38    30    25    20   18   15    8    4    6.8M    3.5M
     ↑     ↑                                       ↑                            ↑
   Source Dest                                   DMA                        Cache
   ready  ready                                channels                      misses
```

**Bottleneck signatures:**
- **High MPU% (>80% on multiple MPUs)** → Compute bottleneck (P4 logic too complex)
- **High DMISS (>1M/s)** → CB cache thrashing (poor locality)
- **High CH0/CH1 (>10)** → DMA channel saturation
- **High RDS/WRS (>5)** → Memory bandwidth bottleneck

---

### Step 3: Check Pipeline Drops (phb_drops)

**Use vanilla asicmon:**
```bash
PAL_CARD_UUID=$CARD_UUID asicmon | grep phb_drops
```

**Example output:**
```
PTD
  DMA: ... phb_drops=4200649519
PRD
  DMA: ... phb_drops=0
```

**Interpretation:**

**PTD (TX pipeline) drops:**
- **At line rate + high drops?** → ✅ **Expected** (flow control working)
- **Below line rate + high drops?** → ❌ **Problem** (investigate further)

**Drop meanings (when below line rate):**
1. **Spurious PHVs:** Scheduler inserted token but no work posted (delay in turning off scheduler)
2. **QP window full:** All paths have AWND=0 or QWND=0
3. **Path window full:** Specific path has PWND=0

**For detailed per-stage drops:**
```bash
# Ask user first - resets counters!
PAL_CARD_UUID=$CARD_UUID asicmon -P | grep DROP/S
```

**Example with per-stage drops:**
```
UD0_P4DMA
 S SRDY  DRDY  ...  DROP/S
S0    1   100  ...       0
S1   19   100  ...   20.7M  ← Spurious PHVs or RX drops
S2   19   100  ...   20.7M
S3   25   100  ...   20.7M  ← QP-level window full
S4   23   100  ...   23.3M  ← Path-level window full
```

**Drop stage mapping (Meta RoCE TX):**
- **S0/S1 drops:** Spurious PHVs (scheduler lag)
- **S2/S3 drops:** QP-level window full (path_sel stage checks AWND/QWND)
- **S3/S4 drops:** Path-level window full (specific path PWND=0)

**Next steps if drops are problematic:**
- Check CC state: `nicctl show rdma queue-pair --raw` (AWND, QWND, PWND)
- Check retx ring: `path_cb2.retx_pi` vs `path_cb2.retx_ci`
- Check path bitmap: `SQCB1.path_bitmap` (are paths active?)

---

### Step 4: Check TXS XOFF (Scheduler Backpressure)

**Use vanilla asicmon:**
```bash
PAL_CARD_UUID=$CARD_UUID asicmon | grep "TX Scheduler" -A1
```

**Example output:**
```
== TX Scheduler 0 ==
 Set=15121192 Clear=52882156 XOFF: 0% 0% 4% 96% 0% 0% 0% 0% 0% 0% 0% 0% 0% 0% 0% 0%
 TXDMA: 2682390843  RXDMA: 2572042769  SXDMA: 20508
      ↑                                     ↑
    Queue 0                              Queue 3 (96% XOFF!)

== TX Scheduler 1 ==
 XOFF: 0% 0% 2% 97% 0% 0% 0% 0% 0% 0% 0% 0% 0% 0% 0% 0%
```

**Interpretation:**

**Queue 3 high XOFF (95-99%):**
- **At line rate?** → ✅ **Expected** (rate matching)
  - PCIe Gen5 can push ~505 Gbps per direction
  - Wire port limited to 400 Gbps
  - Headers add overhead (Ethernet 14-18B, RDMA ~28B+)
  - TXS applies backpressure to prevent overflow
- **Below line rate?** → ❌ **Problem** (downstream bottleneck)
  - Check wire port status
  - Check receiver flow control

**Rule:** TXS XOFF is ONLY a concern if wire bandwidth is LOW while XOFF is HIGH.

---

### Step 5: Check PCIe Bandwidth & Link

**5a. Verify PCIe generation and link width:**
```bash
lspci -s <BDF> -vvv | grep -E "LnkSta.*Speed|Width"
```

**Example output:**
```
LnkSta: Speed 32GT/s (downgraded), Width x16 (ok)
```

**Decode speed:**
- `32GT/s` = **PCIe Gen5**
- `16GT/s` = **PCIe Gen4**
- `8GT/s` = **PCIe Gen3**

**5b. Calculate theoretical bandwidth:**

PCIe uses 128b/130b encoding (Gen3+):

```
Gen5 x16: 32 GT/s × 16 lanes × (128/130) = 504.6 Gbps per direction
Gen4 x16: 16 GT/s × 16 lanes × (128/130) = 252.3 Gbps per direction
Gen3 x16:  8 GT/s × 16 lanes × (128/130) = 126.2 Gbps per direction

Bidirectional:
Gen5 x16: 1009.2 Gbps total (126.15 GB/s)
Gen4 x16:  504.6 Gbps total (63.08 GB/s)
Gen3 x16:  252.5 Gbps total (31.56 GB/s)
```

**5c. Get actual PCIe bandwidth:**
```bash
PAL_CARD_UUID=$CARD_UUID asicmon -b
```

**Example output:**
```
PNI PCIe:
  cfg_port_ctl=0x000000b7 sta_port=0x0000000f
                        Read      Write
  Bandwidth (Gbps):  377.217    381.927
  Latency Read:
    <2.5us       |####################| 100.0%
    2.5-5.0us    |                    |   0.0%
    5.0-7.5us    |                    |   0.0%
    >7.5us       |                    |   0.0%
  Latency Write:
    <2.5us       |####################| 100.0%
    2.5-5.0us    |                    |   0.0%
    5.0-7.5us    |                    |   0.0%
    >7.5us       |                    |   0.0%
```

**Analysis:**
- **Total BW ≈ theoretical max?** → PCIe bottleneck
- **Total BW low + high latency (>5µs)?** → Memory/DMA bottleneck
- **Total BW low + low latency (<2.5µs)?** → Application not posting enough work

**Example (from real smc12 data):**
- PCIe Gen5 x16 theoretical: 504.6 Gbps per direction
- Measured: 377.2 + 381.9 = 759.1 Gbps total
- Utilization: 759.1 / 1009.2 = **75%** → No PCIe bottleneck ✅

---

### Step 6: Check Application Queue Depth

**Get QP state:**
```bash
nicctl show rdma queue-pair --raw -c $CARD_UUID | grep -E "sq_cindex|proxy_pindex"
```

**Look for:**
- **`sq_cindex ≈ proxy_pindex`** → SQ nearly empty (application bottleneck)
  - Application not posting WQEs fast enough
  - Increase queue depth or pipeline submissions
- **Large gap between cindex and pindex** → Plenty of work queued (healthy)

**Check doorbell rate:**
```bash
PAL_CARD_UUID=$CARD_UUID asicmon | grep "Doorbell" -A1
```

**Example:**
```
== Doorbell ==
Host=175 Local=2247165 Sched0=68003345 Sched1=8818651638
```

**Or with asicmon -P:**
```bash
PAL_CARD_UUID=$CARD_UUID asicmon -P | grep "WQE/S"
```

**Example:**
```
DOORBELL
  EXP/S  WQE/S  AXI/S   TMR/S
      0   5.8K  12.6M  577.5K
       ↑
    WQE posting rate
```

**Low WQE/S (<1K) + low bandwidth** → Application bottleneck

---

## asicmon Command Reference

### asicmon (vanilla) - Safe, Non-Destructive ✅

**Shows cumulative counters since boot:**
- Stage utilization, XOFF, idle %
- TX scheduler XOFF per queue
- Pipeline drops (phb_drops)
- Doorbell counts
- HCache hit/miss
- Memory utilization

**Usage:**
```bash
source /etc/profile.d/amd_ainic_user_profile_update.sh
PAL_CARD_UUID=$CARD_UUID asicmon
```

**Key sections:**
```
== TX Scheduler 0 ==
 XOFF: 0% 0% 4% 96% ...  ← Per-queue backpressure

== UDMA0 ==
 S4: (utl/xff/idl) in= 25/ 10/ 65 out= 30/ 85/ 40  ← Stage 4: 85% out XOFF!

PTD
  DMA: ... phb_drops=4200649519  ← TX pipeline drops

== Doorbell ==
Host=175 Local=2247165 ...  ← Doorbell activity
```

**Pros:** Safe, always available, shows long-term trends
**Cons:** Cumulative (hard to see current state), no per-stage drops, no wire BW

---

### asicmon -b - PCIe Bandwidth Monitor ✅

**Shows PCIe read/write bandwidth and latency:**
- Gbps per direction (Read/Write)
- Latency histograms (<2.5µs, 2.5-5µs, 5-7.5µs, >7.5µs)

**Usage:**
```bash
PAL_CARD_UUID=$CARD_UUID asicmon -b
```

**When to use:**
- Check if PCIe is bottleneck
- Measure actual bandwidth vs theoretical
- Identify PCIe latency issues

**Pros:** Safe, shows actual bandwidth in Gbps, latency breakdown
**Cons:** Doesn't show wire bandwidth or pipeline details

---

### asicmon -s <seconds> - Quick PPS Check ✅

**Shows packets per second over interval:**

**Usage:**
```bash
PAL_CARD_UUID=$CARD_UUID asicmon -s 5
```

**Example output:**
```
PPS (1100 MHz core): VULMON_PIPE_SXDMA=0 UD0(TX/RX)=11208095/5592531 UD1(TX/RX)=11659958/5874689 P4IG=0 P4EG=22924078
```

**Interpretation:**
- UD0/UD1 TX/RX PPS breakdown
- Total PPS = sum of all pipelines
- Can estimate bandwidth if packet size is known

**Pros:** Quick, simple, safe
**Cons:** Only PPS (not Gbps), no latency, no drops, no stage details

---

### asicmon -P - P4 Pipeline Monitor ⚠️ RESETS COUNTERS!

**Detailed per-stage and wire bandwidth analysis:**
- Per-stage: SRDY, DRDY, MPU%, drops, DHIT/DMISS, DMA channels
- Wire bandwidth: PBI_NET_BPS (ingress), PBE_NET_BPS (egress)
- Pipeline BW: PR_PPS, PR_BPS per UD pipeline
- TXS XOFF detailed breakdown
- Doorbell stats

**Usage:**
```bash
# ALWAYS ask user first - resets counters!
PAL_CARD_UUID=$CARD_UUID asicmon -P
```

**Example output:**
```
======== P4MON RESULTS, period=200.000msec polls=100  ========
UD0_P4DMA
  AXI_LAT_NS     BKT_15    BKT_MID     BKT_20
        1.4K        83%        17%         0%
 S SRDY  DRDY  MPU0  MPU1  MPU2  MPU3  MPU4  MPU5  FREE  CH0  CH1  RDS  WRS    DHIT   DMISS  DROP/S 
S0    1   100    45    25    20     9     7     7    60    2    0    0    2   30.3M       0       0 
S1   19   100    27    13     8     4     7     4    61    2    0    0    0   13.1M    1.6M   20.7M 
S4   23   100    18     2     1     8     1     0    54    7    0    1    0    1.1M  818.0K   23.3M 
  PT0_PPS  PR_PPS  PR_BPS
     12.1M   11.0M   178.3G

PB_SWITCH
  PBI_NET_BPS  PBI_UD0_BPS  PBI_UD1_BPS 
       416.8G       206.5G       198.8G
  PBE_NET_BPS  PBE_UD0_BPS  PBE_UD1_BPS
       405.2G       178.3G       215.4G

TXS XOFF Status                       UD0[0:15]  |  UD1[0:15]
  0  0  4 96  0  0  0  0  0  0  0  0  0  0  0  0  0  0  2 97  0  0  0  0  0  0  0  0  0  0  0  0
```

**Key metrics:**
- **SRDY**: % time stage has data to process
- **DRDY**: % time downstream can accept (100 = no backpressure)
- **MPU%**: Per-MPU utilization
- **DHIT/DMISS**: D-cache (CB) hits/misses
- **DROP/S**: Drops per second at this stage
- **CH0/CH1**: DMA channel usage
- **RDS/WRS**: Memory read/write requests

**Pros:** Most detailed, shows wire BW, per-stage breakdown
**Cons:** Resets counters (destructive), need user approval

---

### asicmon -v - Verbose ✅

**All of vanilla asicmon PLUS:**
- AXI utilization/latency per channel
- Per-filter AXI stats
- PBUS utilization breakdown

**Usage:**
```bash
PAL_CARD_UUID=$CARD_UUID asicmon -v
```

**When to use:** Deep ASIC analysis, memory bandwidth investigation

**Pros:** Safe, very detailed
**Cons:** Verbose output, cumulative (not snapshot)

---

## Real-World Examples

### Example 1: Unidirectional Traffic (TX Only)

**Scenario:** ib_write_bw running on 400G port

**Results:**
```bash
# asicmon -b
PNI PCIe:
  Bandwidth (Gbps):  Read: 387.5  Write: 5.8

# asicmon -s 5
UD0(TX/RX)=5986248/0 UD1(TX/RX)=5811112/0
                 ↑                      ↑
           TX only (RX=0)         TX only (RX=0)

# asicmon -P
PBI_NET_BPS: 416.8G (ingress - from host to wire)
PBE_NET_BPS: 405.2G (egress - wire sending)
```

**Analysis:**
- Wire BW: ~400 Gbps → **At line rate** ✅
- PCIe: 387.5 Gbps read (DMA from host memory) → 97% of line rate
- TX-only pattern: RX PPS = 0, low PCIe write (only 5.8 Gbps for ACKs)
- **Verdict:** Healthy, at line rate

---

### Example 2: Bidirectional Traffic

**Scenario:** ib_write_bw bidirectional mode

**Results:**
```bash
# asicmon -b
PNI PCIe:
  Bandwidth (Gbps):  Read: 377.2  Write: 381.9
  Total: 759.1 Gbps

# asicmon -s 5
UD0(TX/RX)=11208095/5592531 UD1(TX/RX)=11659958/5874689
Total: 22.9M TX + 11.5M RX = 34.4M PPS

# asicmon -P
PBI_NET_BPS: 416.8G
PBE_NET_BPS: 405.2G
UD0 PR_BPS: 178.3G
UD1 PR_BPS: 215.4G
```

**Analysis:**
- Wire BW: ~400 Gbps both directions → **At line rate** ✅
- PCIe: 759 Gbps total (75% of Gen5 x16 capacity) → No PCIe bottleneck ✅
- TX/RX balanced: ~2:1 ratio (22.9M TX, 11.5M RX)
- **Verdict:** Healthy, at line rate, balanced load

---

### Example 3: Pipeline Drops at Line Rate (Expected)

**Scenario:** High drops but at line rate

**Results:**
```bash
# asicmon -P
UD0_P4DMA
 S SRDY  DRDY  ...  DROP/S
S1   19   100  ...   20.7M  ← 20M drops/sec!
S4   23   100  ...   23.3M  ← 23M drops/sec!

PBE_NET_BPS: 405.2G  ← At line rate (400G port)
```

**Analysis:**
- Wire BW at line rate → Drops are **expected flow control** ✅
- S1 drops: Spurious PHVs (scheduler lag)
- S4 drops: Path window full (PWND=0 on some paths)
- DRDY=100% on all stages → No pipeline backpressure
- **Verdict:** Normal behavior, flow control working correctly

**Why drops are OK here:**
- At line rate, system is saturated
- Drops indicate: windows full (AWND/PWND), spurious scheduler tokens
- These are **soft drops** (intentional flow control), not errors

---

### Example 4: TXS XOFF at Line Rate (Expected)

**Scenario:** High TXS queue XOFF but at line rate

**Results:**
```bash
# asicmon
== TX Scheduler 0 ==
 XOFF: 0% 0% 4% 96% 0% 0% 0% 0% 0% 0% 0% 0% 0% 0% 0% 0%
              ↑
        Queue 3: 96% XOFF!

# asicmon -P
PBE_NET_BPS: 405.2G  ← At line rate

# lspci
LnkSta: Speed 32GT/s, Width x16  ← PCIe Gen5
```

**Analysis:**
- PCIe Gen5 can push 505 Gbps per direction
- Wire port limited to 400 Gbps
- TXS queue 3 XOFF 96% → **Rate matching, expected** ✅
- **Verdict:** Normal behavior, not a bottleneck

**Why XOFF is OK here:**
- PCIe faster than wire (505 > 400 Gbps)
- Headers add overhead (Ethernet, RDMA)
- TXS applies backpressure to prevent overflow
- Wire is saturated → System working correctly

---

### Example 5: Stage Backpressure (Bottleneck)

**Scenario:** Only 200 Gbps instead of 400 Gbps

**Hypothesis:** Pipeline stage bottleneck

**Investigation:**
```bash
# asicmon
S3: (utl/xff/idl) in= 25/  0/ 75 out= 30/ 10/ 60  ← Low out XOFF
S4: (utl/xff/idl) in= 30/ 10/ 60 out= 35/ 85/ 15  ← 85% out XOFF!
S5: (utl/xff/idl) in= 35/ 85/ 15 out= 40/  0/ 60  ← S5 receiving backpressure

# asicmon -P (focus on S5 - downstream of high XOFF)
S5   25    15    52    44    38    30    25    20   18   15    8    4    6.8M    3.5M
     ↑     ↑                                       ↑                            ↑
   SRDY  DRDY                                    DMA                        DMISS
         Low!                                  High!                        High!
```

**Analysis:**
- S4 has 85% out XOFF → S5 is bottleneck
- S5 DRDY=15% → S5 can only accept 15% of the time
- S5 high DMA channels (18, 15) → DMA saturated
- S5 high DMISS (3.5M) → CB cache thrashing
- **Bottleneck: S5 DMA channel saturation + cache misses**

**Next steps:**
- Improve CB locality (reduce cache misses)
- Reduce DMA commands per packet
- Check memory bandwidth: `asicmon` → memory utilization %

---

## Bottleneck Decision Tree

```
┌─────────────────────────────────────────────┐
│ Step 0: Get card UUID per node (REQUIRED)  │
│   nicctl show card | grep <BDF>            │
└────────────────┬────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────────┐
│ Step 1: Check wire bandwidth               │
│   asicmon -P: PBI_NET_BPS / PBE_NET_BPS    │
│   nicctl show port: port speed             │
└────────────────┬────────────────────────────┘
                 │
         ┌───────┴───────┐
         │               │
    At line rate?   Below line rate
         │               │
         ▼               ▼
    ✅ HEALTHY      ❌ BOTTLENECK
    (drops/XOFF     Continue →
     expected)
         │
         │
         ▼
┌─────────────────────────────────────────────┐
│ Step 2: Check stage XOFF                   │
│   asicmon: S0-S7 (utl/xff/idl) out xoff    │
└────────────────┬────────────────────────────┘
                 │
         ┌───────┴────────┐
         │                │
    All <50%         >50% found?
         │                │
         ▼                ▼
    Continue        Pipeline backpressure
                    asicmon -P: check next stage
                      - High MPU? → Compute
                      - High DMISS? → Cache
                      - High CH0/CH1? → DMA
                      - High RDS/WRS? → Memory
         │
         ▼
┌─────────────────────────────────────────────┐
│ Step 3: Check drops                        │
│   asicmon: phb_drops                       │
│   asicmon -P: per-stage DROP/S             │
└────────────────┬────────────────────────────┘
                 │
         ┌───────┴────────┐
         │                │
    Low drops        High drops
         │                │
         ▼                ▼
    Continue        Check CB state:
                    - AWND/QWND/PWND
                    - retx_pi vs retx_ci
                    - path_bitmap
         │
         ▼
┌─────────────────────────────────────────────┐
│ Step 4: Check TXS XOFF                     │
│   asicmon: TX Scheduler XOFF               │
└────────────────┬────────────────────────────┘
                 │
         ┌───────┴────────┐
         │                │
    Low XOFF         High XOFF?
         │                │
         ▼                ▼
    Continue        External backpressure
                    - Port/link issue?
                    - Receiver flow control?
         │
         ▼
┌─────────────────────────────────────────────┐
│ Step 5: Check PCIe                         │
│   lspci: verify gen/width                  │
│   asicmon -b: bandwidth & latency          │
└────────────────┬────────────────────────────┘
                 │
         ┌───────┴────────────────┐
         │                        │
    BW ≈ max?              BW low?
         │                        │
         ▼                        ▼
    PCIe bottleneck      ┌───────┴────────┐
                         │                │
                    High latency?   Low latency?
                         │                │
                         ▼                ▼
                    Memory/DMA       Continue
                    bottleneck
                                          │
                                          ▼
                         ┌────────────────────────────────┐
                         │ Step 6: Check queue depth      │
                         │   nicctl: cindex vs pindex     │
                         │   asicmon: WQE/S doorbell rate │
                         └────────────────┬───────────────┘
                                          │
                                  ┌───────┴────────┐
                                  │                │
                             Queue full?     Queue empty?
                                  │                │
                                  ▼                ▼
                             Continue        Application
                                            bottleneck
```

---

## Drop Interpretation Rules

### When Drops Are OK ✅

**High drops + at line rate:**
- System is saturated (reaching maximum throughput)
- Drops indicate flow control mechanisms working:
  - **S1 drops:** Spurious PHVs (scheduler delay in turning off)
  - **S3 drops:** QP-level window full (all paths AWND=0 or QWND=0)
  - **S4 drops:** Path-level window full (specific path PWND=0)
- These are **soft drops** (intentional), not packet errors
- **No action needed**

### When Drops Are a Problem ❌

**High drops + below line rate:**
- Indicates real bottleneck preventing line rate
- Investigate:
  - Which stages have high drops? (asicmon -P: DROP/S)
  - Check CB state: `nicctl show rdma queue-pair --raw`
    - S3 drops → Check AWND, QWND values
    - S4 drops → Check PWND per path
  - Check retx ring: `path_cb2.retx_pi` vs `retx_ci`
  - Check path bitmap: `SQCB1.path_bitmap` (are paths active?)

### Drop Rate Context

**Example from smc12 bidirectional test:**
```
RX PPS: 11.5M packets/sec
S1 drops: 20.7M drops/sec  (1.8x RX rate)
S4 drops: 23.3M drops/sec  (2.0x RX rate)
Wire BW: 405 Gbps (at line rate)
```

**Interpretation:** Drop rate > RX rate is OK when at line rate because:
- Scheduler generates spurious tokens (S1 drops)
- Window management drops packets that can't be sent yet (S3/S4)
- These drops prevent queue overflow and maintain flow control

---

## TXS XOFF Interpretation Rules

### When XOFF Is OK ✅

**High XOFF + at line rate:**
- **Rate matching:** PCIe can push faster than wire can send
- Example: PCIe Gen5 (505 Gbps) → 400G port
- Headers add overhead (Ethernet 14-18B, RDMA ~28B+)
- TXS queue applies backpressure to prevent overflow
- **This is expected and healthy**

### When XOFF Is a Problem ❌

**High XOFF + below line rate:**
- Indicates downstream bottleneck
- Check:
  - Port status: `nicctl show port` (is link UP?)
  - Wire bandwidth: `asicmon -P` (PBE_NET_BPS)
  - Receiver flow control: Is remote side sending pause frames?

### XOFF per Queue

Different queues serve different traffic types:
- **Queue 0-2:** Lower priority or different traffic classes
- **Queue 3:** Typically RDMA data traffic (most common high XOFF)
- **Queues 4-15:** Other traffic types or unused

High XOFF on queue 3 is common for RDMA workloads at line rate.

---

## Common Errors & Troubleshooting

### Error: pal_reg_wr32w Assertion Failed

**Symptom:**
```
pal_reg_rd32w: failed to map pa 0x325530c8
asicmon: sdk/platform/pal/src/ipc/x86_64/reg.c:174: pal_reg_wr32w: Assertion `0' failed.
```

**Cause:** Wrong card UUID for the node

**Fix:**
```bash
# Get correct UUID for this node
nicctl show card | grep -A1 <BDF>

# Use the correct UUID
PAL_CARD_UUID=<correct-uuid> asicmon -b
```

**Prevention:** Always run Step 0 to map node → card UUID

---

### Error: Command Not Found

**Symptom:**
```
asicmon: command not found
```

**Cause:** Environment not sourced

**Fix:**
```bash
source /etc/profile.d/amd_ainic_user_profile_update.sh
which asicmon  # Should show /usr/sbin/asicmon
```

---

### Warning: Reset Window Too Short

**Symptom (from asicmon):**
```
!!! WARN !!! Read counters took longer than load window.
!!! WARN !!! Some latch counters may be unreliable.
!!! WARN !!! Increase the load window and try again.
```

**Cause:** System load or timing variance

**Impact:** Latched counters may have slight inaccuracy

**Fix:** Usually safe to ignore for general debugging. If critical precision needed, run asicmon multiple times and average results.

---

## Performance Baselines

**Expected throughput (Vulcano, single QP, single path):**
- **Write bandwidth:** ~24 Gbps (3 GB/s) per QP
- **Read bandwidth:** ~20 Gbps (2.5 GB/s) per QP
- **Latency (small messages):** ~2-5 µs

**Scaling:**
- **Multi-path:** Linear scaling up to available ports
- **Multi-QP:** Near-linear scaling up to ~8 QPs, then diminishing returns

**Port speeds:**
- **400G port:** 400 Gbps = 50 GB/s
- **200G port:** 200 Gbps = 25 GB/s
- **100G port:** 100 Gbps = 12.5 GB/s

**PCIe Gen5 x16:**
- **Per direction:** 504.6 Gbps (63.08 GB/s)
- **Bidirectional:** 1009.2 Gbps (126.15 GB/s)

*(Note: Actual numbers depend on message size, CPU, memory, network topology)*

---

## Quick Reference: Command Summary

| Command | Safe? | What It Shows | Use When |
|---------|-------|---------------|----------|
| `nicctl show card` | ✅ | Card UUID mapping | **Step 0 (always)** |
| `nicctl show port -c` | ✅ | Port speed, state | Get line rate baseline |
| `lspci -s <BDF> -vvv` | ✅ | PCIe gen/width | Verify PCIe capabilities |
| `asicmon` | ✅ | Stage XOFF, phb_drops, TXS | Stage backpressure, drops |
| `asicmon -b` | ✅ | PCIe BW (Gbps), latency | PCIe bottleneck check |
| `asicmon -s 5` | ✅ | PPS breakdown | Quick throughput check |
| `asicmon -v` | ✅ | Verbose ASIC state | Deep ASIC analysis |
| `asicmon -P` | ⚠️ Resets | Wire BW, per-stage detail | **Line rate check, deep debug** |
| `nicctl show rdma queue-pair --raw` | ✅ | CC state, windows, CB | RDMA-specific state |
| `nicctl show rdma statistics -c` | ✅ | Retx counters | RDMA error rates |

---

## See Also

- `06-debugging.md` — Correctness debugging (anomalies, QP errors, NAKs)
- `01-protocol.md` — Wire protocol, sequence numbers, ACK/NAK formats
- `02-tx-pipeline.md` — TX dataplane stages (S0-S7 functions)
- `03-rx-pipeline.md` — RX dataplane stages
- `modification-guide/stage-coupling.md` — CB field ownership per stage
