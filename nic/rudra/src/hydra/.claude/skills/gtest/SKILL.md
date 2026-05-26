---
name: gtest
description: Run hydra gtest test cases inside the pensando/nic container
triggers:
  - run gtest
  - run hydra gtest
  - run unit test
  - run gtest testcase
  - debug gtest
---

# Run GTest Skill

Run the hydra gtest binary inside the `pensando/nic` Docker container.
Wraps `rudra/test/tools/run_ionic_gtest.sh`, which itself drives `setup_dol.sh
--debug` so a per-action `/sw/nic/model.log` is captured for every gtest run
(the model log is always on for gtest; there is no separate `--debug` flag).

## Usage Examples

- "run gtest"  -- runs the full default suite (`-*scale*` filter, the .job.yml default)
- "run gtest testcase IPv4/resp_rx.write_only_verify_payload_and_ack/0"
- "run gtest *resp_rx*"
- "run gtest --aq" -- use the AQ binary (`hydra_gtest_aq`) instead of `hydra_gtest`

## Available test names

Test names come from the gtest binary itself; list them inside the container:

```bash
docker exec <cid> /sw/nic/rudra/build/hydra/x86_64/sim/rudra/vulcano/bin/hydra_gtest --gtest_list_tests
```

Common test groups (each has many parameterized variants):
- `req_tx.*` -- SQ-side request transmit
- `IPv4/resp_rx.*` / `IPv6/resp_rx.*` -- response RX (verify ACK back to uplink)
- `mp_resp_rx.*` -- multi-path response RX
- `req_retx_rto.*`, `req_retx_sack.*`, `req_retx_brnr.*` -- retransmission
- `resp_rx_sack_tx.*` -- selective ACK TX

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `--testcase` | `-*scale*` | gtest filter pattern (`--gtest_filter=`); excludes scale tests by default |
| `--asic` | `vulcano` | `vulcano` or `salina` |
| `--p4-program` | `hydra` | `hydra` or `pulsar` |
| `--dma-mode` | `uxdma` | DMA mode |
| `--aq` | (off) | Use `hydra_gtest_aq` binary instead of `hydra_gtest` |
| `--container` | (auto) | Docker container ID |

## Script

Run via `quiet-run.sh`. The wrapper logs full output to
`/tmp/claude-skills/gtest-*.log`; read the log for full test output and
post-process the model.log path printed there.

```bash
.claude/skills/scripts/lib/quiet-run.sh gtest \
  .claude/skills/scripts/test/run_gtest.sh [options]
```

## Steps

1. Parse user request for `--testcase`, `--asic`, `--p4-program`, `--aq`.
2. **Container selection**: same auto-detect as `dol`/`build` skills.
3. Run the script. It runs as the container's default user (root) so that
   `setup_dol.sh` can manage root-owned process/files under `/sw/nic` and
   `/var/log/pensando/`.
4. After completion, the model log is at `/sw/nic/model.log` (and a
   collected copy at `/sw/nic/hydra_logs/model.log`). Use
   `nic/tools/parse.py --model-log /sw/nic/model.log` inside the container
   to produce an annotated `model1.log`.

## Equivalent direct command

The skill wraps the canonical `.job.yml` `hydra-vulcano-gtest` invocation,
minus the tarball pre-extraction (the local sim build already populates the
expected paths):

```bash
# inside pensando/nic container, as root
cd /sw/nic
ARCH=x86_64 PIPELINE=rudra ASIC=vulcano P4_PROGRAM=hydra PCIEMGR_IF=1 DMA_MODE=uxdma PROFILE=qemu PLOG_LEVEL=info \
  ./tools/core_count_check.sh \
&& make -C /sw pull-assets-qemu-rdma \
&& DMA_MODE=uxdma ASIC=vulcano P4_PROGRAM=hydra \
   GTEST_BINARY=/sw/nic/rudra/build/hydra/x86_64/sim/rudra/vulcano/bin/hydra_gtest \
   GTEST_FILTER='-*scale*' PROFILE=qemu LOG_FILE=hydra_gtest.log \
   rudra/test/tools/run_ionic_gtest.sh
```

To narrow to a single test, set `GTEST_FILTER` to the exact test name (single
quotes preserve any wildcards or slashes).

## Notes

- Tests must be run after a successful sim build (`build vulcano hydra sim`)
  and gtest build (`build-gtest`).
- Sim/model state from a previous DOL/gtest run can persist; if a run hangs
  early, kill stale `qemu-system-riscv64` / `vul_model` processes in the
  container and re-run.
- The `--aq` AQ binary covers admin queue / control-plane tests; otherwise
  use the default `hydra_gtest`.
