---
name: p4pd TCAM swkey packs multi-byte keys MSB-first (store byte arrays reversed)
description: When programming a P4 TCAM/CAM key from firmware, multi-byte array key fields (IPv6 addr, MAC) must be stored REVERSED in the swkey; p4pd consumes swkey[N-1] as the most-significant byte
type: feedback
originSessionId: 985b82a6-338f-4c36-becf-d4fe3bc02d7f
---
p4pd's generated `build_hw_key` (p4gen `p4pd.cc`) assembles the hardware key
**MSB-first**, consuming the swkey byte-array field from the HIGHEST index down:
for a 16-byte IPv6 key it reads `swkey->hdr_..._ipv6_dstAddr[15]` first, `[14]`
next, ... `[0]` last. The packet's address is extracted in wire order, so wire
byte 0 lines up with swkey index **[15]**.

**Why:** to make the swkey produce a HW key matching the packet, the array must
hold the address **reversed** (`swkey[i] = wire[N-1-i]`). A plain forward
`memcpy` mismatches and the entry never hits.

**How to apply:**
- Byte-array key fields (IPv6/MAC/etc.): reverse the bytes into the swkey.
- Scalar key fields (e.g. IPv4 `uint32`): assembling big-endian
  (`ip[0]<<24 | ip[1]<<16 | ...`) already lands reversed in little-endian host
  memory, so those "just work" with no explicit flip — which is exactly why an
  IPv4 path can pass while the sibling IPv6 path silently drops. Test both.
- First seen: hydra `rdma_local_ip_check` v6 hit key (forward memcpy dropped all
  legit v6 RoCE; caught by the AQ gtest, not v4-only DOL).
