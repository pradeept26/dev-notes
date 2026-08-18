---
name: Hydra gtest — non-AQ binary bypasses NicMgr (use no-op arming)
description: To validate any RDMA feature whose datapath is armed by firmware control-plane (CREATE_AH/SET_AV/modify-QP handlers), you MUST use hydra_gtest_aq, not the default hydra_gtest
type: feedback
originSessionId: 985b82a6-338f-4c36-becf-d4fe3bc02d7f
---
The default `hydra_gtest` constructs `g_rdma_driver` with `use_aq=false`
(main.cc). In that mode `meta_roce_driver::create_ht()` / `create_qp()` write
the AH template and QState **straight to memory** — NicMgr never runs, so admin
handlers (CREATE_AH `eth_rdma_impl_aq_ah_create_hdlr`, SET_AV, modify-QP) and any
learn hooks in them **do not fire**. The driver source even says so:
"since NicMgr doesn't run" (meta_roce_driver.cc ~163).

**Why:** the non-AQ path is a shortcut for pure-datapath tests; it deliberately
skips the control plane. `hydra_gtest_aq` (`gtest/aq/`, `g_rdma_driver(true)`)
drives a real adminq, so CREATE_AH etc. execute in the QEMU firmware.

**How to apply:** any feature whose P4 tables are *programmed by firmware* (local-IP
admission check, address→LIF learn, etc.) is UNARMED under `hydra_gtest` and will
silently not-drop / not-match. Put the test in `gtest/aq/` and run the AQ binary.
Pure datapath behavior (given tables already programmed) can stay in the default
binary. Also: a firmware (nicmgr .c) change requires a **full** gtest build
(`make -f Makefile.ainic rudra-vulcano-hydra-gtest`) to rebuild the riscv/QEMU
image — a quick `make -C .../gtest[/aq]` only relinks the x86 binary and leaves
the firmware stale.
