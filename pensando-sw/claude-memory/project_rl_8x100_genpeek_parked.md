---
name: 8x100G RL generic-peek fix — built, PARKED (awaiting HW validation)
description: Generic single peek-recovery table making LLC-meter RL work for 8x100G (ports 4-7); code done+built on a branch, deprioritized 2026-09-09, pending kenya HW test
type: project
originSessionId: 1418ad7a-e393-49d8-aa61-76d2bde9f02b
---
**Status (2026-09-09): PARKED / lower priority.** Code complete, clean-built (fw+nicctl), NOT yet tested on HW. Resume when a new higher-priority req is done and the kenya testbed is free.

**Why:** The LLC-meter RL (gborcar) recovery ("peek") logic was hardcoded to ports 0-3 (4 per-port tables, ud0/ud1 split), so on **8x100G ports 4-7 got throttled RED but never recovered → ~half BW**. RED-set already worked for all 8 (keyed by variable port_index); only RED-clear was 4-port.

**The fix:** collapse the 4 per-port peek tables into ONE generic `pic_rl_meter_peek_tbl` in S4, keyed by a rotating `p_rl_peek_idx` (timestamp low 3 bits, 0-7), gated by a single `pred_peek` bit (set in S1 because apply-block predicates only allow `==`). Makes RED-clear symmetric with RED-set; scales to any port count. Net −324/+68 lines.

**Where it lives:**
- Branch `pradeept/meter_rl_llc_8port` off `gborcar/meter_rl_llc_new` (in repo `/ws/pradeept/ws/usr/src/github.com/pensando/sw-1`). Commits: `8fb72a12eae` (feature) + `b47c24dc5a4` (fix: `!=` → precomputed `pred_peek`). NOT pushed (local only).
- Files: meta_roce tx phv/s0/s1/s3/s4 + nicmgr/plugin/rdma/init.c.
- **Built artifacts stashed:** `/vol/systest/agentq/rl-8x100-pradeept/` — `ainic_fw_vulcano.tar`, `nicctl-…noble…_amd64.deb`, `rudra_vulcano_hydra_host_nicctl_pkg.tar.gz` (version tagged `…dirty` = built one commit before the fix landed, but binaries DO contain the fix; rebuild from branch for a clean tag).

**Pending / to validate on HW (kenya-perf-3/4):**
1. **8x100G (the fix):** flash `meta-roce-8x100G-1`, apply RL, confirm ports 4-7 RED clears + full line rate (was ~half).
2. **2x400G / 4x200G regression:** RL must still pin HOLB to line rate (ports 0-3 now go through the generic table).
3. **Recovery latency (design tradeoff):** rotor sweeps 0-7, so a RED port is peeked ~1-in-8 packets; on <8-port profiles 6/8 rotor values hit non-existent ports and no-op (safe: never RED + meter valid=0). Sub-µs at Mpps but eyeball for any throughput dip vs the 4-port build.

**Optional refinement if #3 matters:** mask rotor to `num_ports` (needs num_ports plumbed into the S1 status action). Left unmasked for the first test.

**Latent (not touched):** old commented-out debug write at `meter_addr+256` now collides with port4's meter (512B region full at 8 ports) — disabled, harmless, but stale if re-enabled.

Related: gborcar's `LLC_RATE_LIMITER_HANDOFF.md` (repo root of his branch); session handoff `~/dev-notes/pensando-sw/session-handoff-holb-rl-2026-09.md`.
