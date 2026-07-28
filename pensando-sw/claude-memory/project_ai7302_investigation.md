---
name: AI-7302 QP4092 hang investigation (resume context)
description: AI-7302 not reproduced on SMC (a-55 or a-8); testbed state + pending next steps for resuming
type: project
originSessionId: 89f159fb-8d11-488b-bb5c-323b690ec310
---
**AI-7302**: `ib_write_bw` QP4092 bidir hang (`-q 4092 -t 2 -r 8`, path_count=2, GPU memory `--use_rocm_dmabuf`) — reported by Prateek Mittal on **evt2** (evt2-c15/c18), FW **1.130.0-a-55**, driver **26.07.11.001**, GPU **gfx1250**, 800G.

**Verdict (as of 2026-07-27): NOT reproduced on SMC.** Tested on SMC (smc1 `10.30.75.198` / smc2 `10.30.75.204`, root/docker; NIC `benic3p1`, card BDF `0000:43:00.0`, GPU `--use_rocm=2`):
- Latest **1.130.2-a-8** AND exact reported **1.130.0-a-55** (exact driver 26.07.11.001) → exact config PASSES at **760 Gb/s line rate** (400G bidir ceiling ~800).
- Baselines 512/1020/2048 all pass. 4092 ladder (4,4 and 2,8) both pass.
- Faithful **8M + n5000** (20,460,000 iters) run **twice** on a-55: 760.06 & 760.08 Gb/s, ~62 min each, near-zero anomalies (PB-drop Δ0/215 then Δ0/4; PRD Δ0) — NO resp_rx_dup_request storm (evt2 had 7.9M-10.2M).

**Conclusion / Why:** same FW+driver passes on SMC but hung on evt2 → NIC FW/driver ruled out; hang is **evt2-environment-specific**. Leading suspect = the **dmabuf memory path** (`--use_rocm_dmabuf`), which is *broken on SMC's kernel 5.15.0-185* on both builds so it could only be tested via peer-mem (`--use_rocm=2`). Other diffs: MI300X vs gfx1250, 400G vs 800G. See [SMC GPU/dmabuf note](reference_smc_gpu_dmabuf.md).

**Current testbed state:** SMC is left on **1.130.0-a-55** (NOT default a-8), path_count restored to 8, clean. ROCm perftest binaries built at `/opt/perftest-a55/rocm/ib_write_bw` (a-55) and `/opt/perftest-mrc/rocm/ib_write_bw` (a-8).

**How to apply / pending next steps when resuming:**
1. Draft AI-7302 update comment (findings above) — NOT yet posted (needs user OK before posting to Jira).
2. Recommended: re-run AI-7302 config on **evt2 with peer-mem** (`--use_rocm=2`, drop `--use_rocm_dmabuf`) — if it passes there, dmabuf is the trigger; if it still hangs, it's GPU/800G config.
3. Consider a separate ticket for the **dmabuf-on-kernel-5.15** breakage (independent of AI-7302).
4. SMC may need restoring to `1.130.2-a-8` when done.
5. Progress was Slacked to prthangar (U02244G2UJJ, DM channel D022B45MVJ7) after each phase.
