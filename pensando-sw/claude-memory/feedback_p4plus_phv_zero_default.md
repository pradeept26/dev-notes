---
name: P4+ PHV fields are zero by default
description: In the pensando/sw P4+ pipeline, PHV fields are zero-initialized by default at pipeline entry; do not add explicit-clear code assuming otherwise
type: feedback
originSessionId: 5c1791ad-e9cb-4ac7-ad27-4732167068b9
---
P4+ PHV fields are **zero by default** at pipeline entry in the pensando/sw
(rudra/hydra/pulsar) P4+ environment.

**Why:** User corrected me (2026-07-13) after I claimed PHV fields aren't
guaranteed zero and proposed an explicit `p.field = 0` clear. They are zero by
default.

**How to apply:** When designing/writing P4+ datapath code, a PHV flag that is
only ever *set* to 1 on a specific path (e.g. pulsar's `stopped_txs`, set only
in the S0 fast-stop case and read later as `== 1`) does NOT need an explicit
clear on the other paths — the default 0 is guaranteed. Don't add defensive
zero-init instructions for PHV fields; it wastes an instruction on the fast path.
