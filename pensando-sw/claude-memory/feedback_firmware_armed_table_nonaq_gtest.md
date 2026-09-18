---
name: Firmware-armed p4e tables + always-on catch-all break non-AQ hydra_gtest
description: Why a firmware-armed p4e admission/drop table with an eager catch-all mass-fails the non-AQ hydra_gtest, and the lazy-arm-on-first-learn fix (rdma_drop en-bit pattern)
type: feedback
originSessionId: 985b82a6-338f-4c36-becf-d4fe3bc02d7f
---
A firmware-armed p4e table that installs an **always-on catch-all/miss entry at init**
(check_init, run by NicMgr) will **mass-fail the non-AQ `hydra_gtest`** while the AQ
binary and HW pass. Seen with the RDMA local-IP admission check (PR #120693): non-AQ
28/128, AQ 64/64, ToT baseline 128/128.

**Why:** NicMgr *init* DOES run in the non-AQ qemu boot ("Nicmgr init completed" in the
log), so `check_init` installs the catch-all. But the non-AQ harness sets up QPs by poking
qstate directly (`rdma_driver::create_ht` `!use_aq` branch = raw `write_mem`, NOT the
`CREATE_AH` admin path) and **never fires the firmware learn hook**, so no per-QP hit is
ever installed. Every test RoCE packet then misses all hits → catch-all → drop → no ACK
("Actual Packet: 0 bytes", broad resp_rx/req_tx/retx failures, no P4E drop reason logged
because decode_roce is skipped by the `rdma_ip_miss==0` guard). AQ passes because its admin
path (`create_ht` use_aq=true → `rdma_admin_wqe_create_modify_qp` → CREATE_AH/SET_AV) learns
the hit. The non-AQ harness **excludes p4pd libs** (`SSDK_EXCLUDE_LIBS += p4pd_rudra`), so you
cannot install a TCAM hit host-side; only raw `write_mem`/`write_qstate` are available.

**Fix (the idiomatic pattern):** arm enforcement **lazily on the first successful learn**,
not at init. Move the catch-all install out of `check_init` into the first
`eth_rdma_impl_local_ip_learn` (one-shot bool, reset in check_init; program the hit before the
catch-all so the just-learned IP isn't self-dropped). Non-AQ never learns → fail-open (default
hit) → 128/128; AQ/HW learn → armed → enforce. Bonus: closes the fleet-wide "every NIC drops
all inbound RoCE from boot until a QP learns" window. Commit c6494bd149a.

**Related pattern:** `rdma_drop` gates its table apply behind a firmware-armed enable bit
(`en_drop_test = __table_constant()[P4_RDMA_DROP_EN_BIT]`, decode_roce_opcode constant, stage 1)
so it's never looked up until armed — that's why baseline non-AQ passes despite having rdma_drop.
A stage-0 table (like local_ip_check) can't use that stage-1 bit, and adding a p4e_init→stage0
dependency risks shifting the table off physical stage 0 (breaks the stage-2 counter's
stage-0-PHV-resolve invariant), which is why lazy-arm-in-firmware is preferred over a p4 gate.

**Debug tips:** confirm non-AQ vs AQ arming by grepping the run log for the learn/init trace and
"Nicmgr init completed"; a clean RX-pass/TX-fail split or "Terminated vul_model"/"Model-NOT-
Responding" mid-run is usually model flakiness (re-run) not a code regression — the model is
flaky under load and occasionally mid-run (saw 11/64 once, 64/64 on clean re-run, load 0.77).
