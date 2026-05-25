---
name: CC/Multipath/RCN gtest implementation
description: Plan to implement 19 gtests for Meta RoCE congestion control, multipath bootstrap, and RCN across 5 phases in the AQ binary
type: project
originSessionId: 06475840-2dc3-46f5-b4bd-43a25d851d5f
---
**Plan source:** `10.11.18.33:/home/pradeept/cc-gtest-plan.md` (copied to `/tmp/cc-gtest-plan.md`)

**Why:** Test CC/multipath bootstrap, AIMD steady-state, path lifecycle, and RCN in the P4+ pipeline using AdminQ-based QP setup.

**Branch:** New branch off latest 1.125-a, cherry-pick hydra-meta-roce-structure for docs/knowledge.

**Phases:**
- Phase 1: Fast-Start Bootstrap (7 tests) — `aq/cc_bootstrap_test.cc`
- Phase 2: AIMD Steady-State (3 tests) — `aq/cc_aimd_test.cc`
- Phase 3: Path Lifecycle (4 tests) — `aq/cc_path_lifecycle_test.cc`
- Phase 4: Multipath CC (2 tests) — `aq/cc_multipath_test.cc`
- Phase 5: RCN (3 tests) — `aq/cc_rcn_test.cc`

**Key infrastructure:**
- New QPs: `g_cc_mp_qp1` (4-path, CC on), `g_rcn_qp1` (4-path, CC+RCN)
- Path count via `nicmgr_rdma_path_update()` API
- CB state readers already exist from NAK test branch

**How to apply:** Start with Phase 1, build incrementally, verify each phase before moving to next.
