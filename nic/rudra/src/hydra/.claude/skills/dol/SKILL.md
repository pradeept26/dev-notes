---
name: dol
description: Run DOL (Day in the Life of) test cases inside the pensando/nic container
triggers:
  - run dol
  - dol test
  - dol tests
  - rdma_write dol
  - run rdma write tests
  - run rdma read tests
---

# Run DOL Skill

Run DOL test cases for RDMA features inside the `pensando/nic` Docker container.

## Usage Examples

- "run dol rdma_write tests"
- "run dol testcase RDMA_REQ_TX_WRITE_ONLY"
- "run rdma_read dol tests"
- "run dol RDMA_REQ_TX_WRITE_ONLY with debug"
- "run all rdma_write dol tests on container abc123"

## Available test cases

The full set of test names lives in `dol/rudra/test/rdma_hydra/rdma_hydra.mlist`
(the `name:` field of each `module:` block). The `--sub` parameter selects
one of these subsets — currently only `rdma_write` is populated; new subsets
should be added there.

A few common test names to start with (match by exact uppercase name from the
mlist):

- `RDMA_REQ_TX_WRITE_ONLY` — simplest SQ-side write; good first smoke test for any change touching SQ sub-LIF init or TXS scheduler.
- `RDMA_RESP_RX_WRITE_ONLY` — simplest RQ-side write.
- `RDMA_REQ_TX_WRITE_FIRST_LAST` — multi-segment write request.
- `RDMA_RX_DUPLICATE_WRITE_ONLY` — RQ duplicate handling.
- `RDMA_RESP_RX_WRITE_OOR_FIRST_LAST` — RQ out-of-range handling.

When in doubt, read the mlist directly and pick the smallest test that
exercises the path you're debugging.

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `--sub` | `rdma_write` | DOL subset (e.g. rdma_write, rdma_read) — must match a `sub:` declared in `dol/rudra/test/rdma_hydra/rdma_hydra.mlist` |
| `--testcase` | (none) | Specific test case to run — must match a `name:` field in the mlist |
| `--debug` | off | Enable debug logs — produces a very large `model.log`; only use with `--testcase` or a small `--sub` |
| `--asic` | `salina` | `salina` or `vulcano` |
| `--p4-program` | `hydra` | `hydra` or `pulsar` |
| `--dma-mode` | `uxdma` | DMA mode |
| `--topo` | `rdma_hydra` | Topology |
| `--feature` | `rdma_hydra` | Feature |
| `--pipeline` | `rudra` | Pipeline |
| `--container` | (auto) | Docker container ID |

## Script

Run via `quiet-run.sh` so the very large containerized DOL output
(especially with `--debug`) is logged to `/tmp/claude-skills/dol-*.log`
instead of dumped into the conversation. Read the log to inspect
test failures; for `--debug` runs, also see the post-processing
section below.

```bash
.claude/skills/scripts/lib/quiet-run.sh dol \
  .claude/skills/scripts/test/run_dol.sh [options]
```

## Steps

1. Parse user request for `sub`, `testcase`, `debug`, and any non-default ASIC/p4 options.
2. **Container selection**: script auto-detects `pensando/nic` containers.
   - If exactly one is running → use it.
   - If multiple → use `$HYDRA_CONTAINER` if set; otherwise **ask the user which one to use** before running.
3. Warn about `--debug` if no `--testcase` is set (large `model.log`).
4. Run the script and stream output.

## Equivalent direct command

The skill wraps these commands (run inside the container at `/sw/nic`):

Both ASICs use `PCIEMGR_IF=1` and a `PROFILE` env var that differs per ASIC.

**salina** (default) — `PROFILE=zephyr`:

```bash
PIPELINE=rudra ASIC=salina P4_PROGRAM=hydra PCIEMGR_IF=1 DMA_MODE=uxdma PROFILE=zephyr \
  rudra/test/tools/dol/rundol.sh --pipeline rudra --topo rdma_hydra \
  --feature rdma_hydra --sub rdma_write --nohntap
```

**vulcano** (`--asic vulcano`) — `PROFILE=qemu`:

```bash
PIPELINE=rudra ASIC=vulcano P4_PROGRAM=hydra PCIEMGR_IF=1 DMA_MODE=uxdma PROFILE=qemu \
  rudra/test/tools/dol/rundol.sh --pipeline rudra --topo rdma_hydra \
  --feature rdma_hydra --sub rdma_write --nohntap
```

## Notes

- **`--debug` produces a very large `model.log`** — only use with a small testcase or subset.
- Tests must be run after a successful `build` (sim platform).
- DOL needs the simulation environment set up; if it complains about missing artifacts, run `build salina hydra sim` first.

## Post-processing a `--debug` run

When DOL is run with `--debug`, `model.log` contains rich per-action detail. To produce a
human-readable, annotated `model1.log` (and a stdout list of executed actions), run
`nic/tools/parse.py` inside the container:

```bash
# inside the pensando/nic container, from /sw/nic
./tools/parse.py --model-log /sw/nic/model.log
```

**File locations (inside container):**
- Input:  `/sw/nic/model.log`  (written by DOL when `--debug` is set)
- Output: `/sw/nic/model1.log` (written next to the input by `parse.py`)

This prints the list of actions executed to stdout (format: `<timestamp> <address> <action_name>`)
and writes `model1.log` next to the input log. Useful flags:

- `--log-dir <dir>` — directory containing `model.log` (alternative to `--model-log`)
- `--asm-dir <dir>` — ASM directory for symbol resolution
- `--loader-info <file>` — MPU program info file
- `--source-info` — annotate output with source file metadata
- `--metrics <file.csv>` — emit a metrics CSV

Only meaningful after a `--debug` run; without `--debug` the model log lacks the
per-action records `parse.py` looks for.
