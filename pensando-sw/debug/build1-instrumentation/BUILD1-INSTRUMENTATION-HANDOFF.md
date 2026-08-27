# Handoff: Build-1 Instrumentation FW (alltoallv RCN-off qwnd→0 counters) — resume from BUILD

**Author:** Pradeep Thangaraju (via Claude)
**Date:** 2026-07-22
**Purpose:** Resume this task in a FRESH Claude session on ANOTHER workspace (the current
worktree `sw-a4-instr` got churned during secure-build attempts; build clean elsewhere).

---

## 0. TL;DR for the new session
1. Check out **`1.130.2-a-4`** tag (base commit `da4d25d29dbcffcc1a10616ddd02761d60a0353f`) in a clean workspace.
2. Apply the patch: **`build1-instrumentation.patch`** (in this dir) — 6 files, 73 insertions.
3. Build a **SIGNED/secure** vulcano AINIC FW (the OPEN problem — see §5). A non-secure build
   is REJECTED by the cards (`Package verification failed, err 255`).
4. Build private **nicctl.bin** (needed to read the new counters).
5. Flash both GT nodes (sequential — parallel SSH failed), reset, bringup, RCN disable.
6. Deploy private nicctl, run alltoallv RCN-off, read the 4 new counters on the wedged QP.

**Artifacts in this dir:**
- `build1-instrumentation.patch` — the code changes (apply on 1.130.2-a-4 tag)
- `base-commit.txt` — base commit + tag
- `BUILD1-INSTRUMENTATION-HANDOFF.md` — this file

---

## 1. Background / why
RCCL `alltoallv` with RCN disabled HANGS on GT Vulcano (reproduced on official 1.130.2-a-4).
Root cause: QP `qp_cwnd_whole` collapses to 0 (below `qwnd_min`), killing both bootstrap triggers.
We believe qwnd→0 happens via the unfloored `force_inactivate` subtraction (`rx_s2:600`), and
that disabled paths strand at cwnd=0. A poller can't catch these µs-scale transitions, so we add
**in-pipeline counters** on a clean a-4 baseline (UNFIXED — this is a MEASUREMENT build, NOT the fix).
Full root-cause context: `/home/pradeept/dev-notes/pensando-sw/debug/alltoallv-rcnoff-hang-20260720-104445/HANDOFF.md`

The related FIX is Vishwas's PR #118783 (`vishwas/alltoallv-rcnoff-cwnd-collapse-fix`, commit 7d2d0c027d2) — do NOT include it here.

---

## 2. The instrumentation (A+B) — what the patch does
Adds 4 counters to SQCB4 (requester RX stats) + 4 rx PHV flags + increments, plus nicctl exposure.

Counters (`bit<32>` each, in `rdma_sqcb4_t`):
- `num_cnt_qwnd_uf_forceinact` — qp_cwnd_whole < qwnd_min right after the force_inactivate subtract (rx_s2)
- `num_cnt_qwnd_uf_fold` — qp_cwnd_whole < qwnd_min after a tx/rx fold (rx_s2)
- `num_cnt_qwnd_uf_other` — below qwnd_min from any other source (catch-all)
- `num_cnt_disabled_drained_cwnd0` — disabled + drained + cwnd<=0 stranded path (Fix-1 gap; **observation only**, no behavior change)

Files changed (all under `nic/rudra/src/hydra/p4/p4plus-16/meta_roce/` unless noted):
- `include/rdma_sqcb.p4` — add 4 counters to `rdma_sqcb4_t`; `__pad_to_64B` 176→48 (ASSERT_CORRECT_CB_SIZE stays 512)
- `rx/meta_roce_rx_phv.p4` — add 4 flags to `meta_roce_rx_global_flags_t`; `__unused_flags` 10→6
- `rx/meta_roce_rx_s2.p4` — set flags at fold (2 sites) + force_inactivate + catch-all. **NOTE the cast:** must be `(int<16>)(bit<16>)p.qwnd_min` — `p.qwnd_min` is `bit<8>` and P4 rejects a direct `bit<8>→int<16>` cast. `(int<16>)d.qp_cwnd_whole` is fine (bit<16>→int<16>).
- `rx/meta_roce_rx_s3.p4` — set `disabled_drained_cwnd0` in the disabled-path branch (observation only)
- `rx/meta_roce_rx_s7.p4` — increment the 4 counters in `req_rx_stats_process` gated on flags
- `nic/infra/ainic/nicctl/pipeline/hydra/rdma_queue.cc` — add 4 fields to `req_rx_cc_stats_t` + CB-read mapping (`fill_sq_stats`) + JSON put + FILL_STATS text print

Apply:
```
cd <fresh-workspace-at-1.130.2-a-4>
git apply /home/pradeept/dev-notes/pensando-sw/debug/build1-instrumentation/build1-instrumentation.patch
# or: patch -p1 < build1-instrumentation.patch
```

---

## 3. Container / build environment
Build inside the `pensando/nic` docker container.
- `/dev-container` skill: kill old containers, `cd $(git rev-parse --show-toplevel)/nic && make docker/background-shell`, then `docker exec <c> git config --global --add safe.directory '*'`, then `make pull-assets`.
- **If building from a git WORKTREE** (not a full checkout): `docker/background-shell` mounts only `/sw` (= worktree), but the worktree's `.git` points into the MAIN repo, so `git describe` fails in-container and the build's version stamping breaks. Workaround used: launch with `make docker/background-shell DOCKER_RUN_ARGS="-v /ws/<user>:/ws/<user>"` so the gitdir resolves. **Recommendation for the new session: use a full checkout of the a-4 tag (or a fresh clone), NOT a worktree**, to avoid this and the "fatal: not a git repository ... modules/ansible-playbooks" submodule noise.

Pull assets (in container, `cd /sw`): `make pull-assets` (uses `/ws/asset_cache` if mounted).

---

## 4. Build commands
### FW (regenerates p4_generated_types.h AND the flashable tar), cwd `/sw`:
```
make P4_PROGRAM=hydra -f Makefile.ainic rudra-vulcano-ainic-fw          # NON-secure (REJECTED by cards)
```
Non-secure output: `/sw/ainic_fw_vulcano.tar`. **This is what I built and it FAILED to flash** (see §5).

### nicctl (private binary — needed to see the new fields), cwd `/sw/nic`:
```
make PIPELINE=rudra ASIC=vulcano P4_PROGRAM=hydra PLATFORM=hw ARCH=x86_64 nicctl.bin
```
Output: `nic/build/x86_64/hw/rudra/vulcano/out/nicctl_bin/nicctl.bin` (~43M).
Depends on `p4_generated_types.h` (regenerated by the FW build) — build nicctl AFTER the FW/P4 build.
The nicctl CB layout matches the flashed FW (both from this patch), so the private nicctl reads the new sqcb4 counters. The INSTALLED nicctl on the node will NOT show them.

---

## 5. ⚠️ OPEN PROBLEM: cards reject the locally-built (unsigned) FW
Flashing the locally-built `ainic_fw_vulcano.tar` fails on every NIC:
```
NIC ... : Package verification failed, err 255
```
Findings:
- The **official** `ainic_fw_vulcano.tar` (from `/vol/builds/hourly/1.130.2-a-4/.../ainic_bundle_1.130.2-a-4.tar.gz`) flashes fine — its images are **pipeline-signed**. My local build's images are **unsigned**; also its MANIFEST `software_version` was empty.
- `nicctl update firmware --force` does NOT help (`Force option is only applicable to pentrust and bootloader1 upgrades`).
- Signing key IS present: `platform/ainic/assets/vulcano_secure/eng_keys/eng.key` (eng_key-pri.pem).
- There is a `BUILD_SECURE=1` path: `nic/tools/ainic/firmware/vulcano/post-image.sh` builds a SECURE package (`make-secure-ainic-package.sh`, signs with eng.key) when `BUILD_SECURE=1`, producing `ainic_fw_vulcano_secure.tar`.
- BUT the secure package needs the **secure zephyr images** at `build/secure/zephyr/zephyr_pcie*.bin`, which are produced only when the **RTOS is built with the secure config** (`platform/rtos-sw/Makefile`: `build-rtos-%-ainic_secure` → `BLD_DIR_SUFFIX=-secure`, `EXTRA_CONFIG=configs/.../ainic_secure.conf`).
- `make rudra-vulcano-ainic-fw` builds the NON-secure RTOS (`build/zephyr/zephyr.bin`), so even `BUILD_SECURE=1 make rudra-vulcano-ainic-fw` fails at packaging: `ERROR: Vulcano zephyr images not found at .../build/secure/zephyr/zephyr_pcie*.bin`.

**Unresolved: the exact top-level command to build a SIGNED vulcano AINIC dev FW** (secure RTOS + secure package with eng.key) that these secure-boot cards accept. This is how Vishwas flashed PR #118783.
**ACTION for new session: get this command from Vishwas / the team, or reverse-engineer the RTOS secure build (build-rtos-vulcano-ainic_secure) + BUILD_SECURE=1 packaging.** Then flash `ainic_fw_vulcano_secure.tar`.

---

## 6. Flash procedure (once a SIGNED FW is built)
Per node (**SEQUENTIAL — parallel flash to both nodes triggered `FW_EXIT=255` / SSH-auth contention on this testbed; do one node at a time**):
```
SSHP="sshpass -p docker ssh -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no"
SCPP="sshpass -p docker scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no"
$SCPP <secure_tar> root@<NODE>:/tmp/ainic_fw_instr.tar
$SSHP root@<NODE> "cd /tmp && sudo nicctl update firmware -i ainic_fw_instr.tar"      # ~5-10 min
$SSHP root@<NODE> "sudo nicctl reset card --all"                                       # wait 8x reset successful
$SSHP root@<NODE> "cd /home/amd/vul-rccl-benchmark && bash setup.sh"                   # bringup
$SSHP root@<NODE> "for p in 0 1 2 3 4 5 6 7; do sudo nicctl update pipeline rdma congestion-control profile -p \$p --rcn disable; done"
```
Version-string caveat: instrumented FW `git describe` = `1.130.2-a-4` (uncommitted patch), SAME as clean a-4 — you CANNOT tell them apart by version. Confirm the instrumented FW is active by the new counters incrementing during traffic (§8).

---

## 7. Deploy private nicctl
```
$SCPP <path>/nicctl.bin root@<NODE>:/tmp/nicctl.bin
$SSHP root@<NODE> "sudo /tmp/nicctl.bin show rdma ..."   # use this, NOT the installed nicctl
```

---

## 8. Validate
1. Confirm on both nodes: RCN disabled, `qwnd_min=2`, `exact_cwnd_enforce=1`, path count 8, 8 roce_ai*_vip devices.
2. Filter `setup_env.sh` to alltoallv-only (already was on this testbed), launch RCN-off run:
   `cd /home/amd/vul-rccl-benchmark && nohup timeout 1800 python3 run.py --runs 1 --output phase1_cc 2>&1 &`
3. Let it wedge (a data QP reaches W=0 / wire idle; use the pollers in
   `/home/pradeept/dev-notes/pensando-sw/debug/alltoallv-rcnoff-hang-20260720-104445/phase0_qwnd_breadth.sh`).
4. On the wedged QP, read via PRIVATE nicctl:
   `sudo /tmp/nicctl.bin show rdma queue-pair --raw --queue-pair-id <N> --lif <lif>` and the stats view.

### Expected result (the whole point)
- `num_cnt_qwnd_uf_forceinact` **> 0**  → qwnd→0 driven by force_inactivate subtract (`rx_s2:600`)
- `num_cnt_qwnd_uf_fold` ≈ 0
- `num_cnt_qwnd_uf_other` ≈ 0
- `num_cnt_disabled_drained_cwnd0` **> 0** → Fix-1 stranding gap quantified

---

## 9. Testbed reference (GT Vulcano multiplane, 2-node)
- GT-1: `10.30.69.101` (RCCL launcher), GT-4: `10.30.69.98` (peer). SSH root/docker, password auth. **Sequential SSH only.**
- 8 Vulcano NICs/node, 4x100G profile, path count 8, ~62 QPs/NIC. Scripts: `/home/amd/vul-rccl-benchmark`.
- Wedged QP seen on GT-4 previously: qp23 (also qp25) on bdf `0000:03:00.0`, lif `02000070-0100-0000-4242-0490818f1e40`.
- **Current state: both nodes healthy on OFFICIAL 1.130.2-a-4, RCN disabled, brought up. Nothing bricked** (the failed flashes never wrote).

## 10. Gotchas already hit (so you don't repeat them)
- P4 cast: `(int<16>)p.qwnd_min` fails (bit<8>); use `(int<16>)(bit<16>)p.qwnd_min`. (Already fixed in the patch.)
- Poller `pgrep -fc 'nicctl update firmware'` self-matches the shell → false "still running". Use `pgrep -x nicctl`.
- Parallel flash to both nodes → 255 / contention. Flash sequentially.
- Worktree + docker: gitdir not mounted → `git describe` fails. Use a full checkout, or mount `/ws/<user>`.
- Non-secure local build → `Package verification failed`. Need the SIGNED/secure build (§5).

## 11. Current (stale) container on THIS host (for reference only; repo churned)
- Container: `pradeept_2026-07-22_04.01.05` (worktree `sw-a4-instr` at /sw). Build tree churned by secure-build attempts (nicctl.bin removed; build/secure never populated). Prefer a fresh build elsewhere.
