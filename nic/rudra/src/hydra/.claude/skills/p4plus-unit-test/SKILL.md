---
name: p4plus-unit-test
description: Run P4+ pytest unit tests inside the pensando/nic container (capsim-driven, per-stage)
triggers:
  - run p4plus unit test
  - run p4+ unit test
  - run capsim test
  - run mputest
  - p4plus-unit-test
---

# Run P4+ Unit Test Skill

Run a P4+ pytest unit test case inside the `pensando/nic` Docker container.
These tests live alongside the P4 source (e.g. `meta_roce/tx/test/`) and
drive `vulsim`/`salsim` (capsim) on a single compiled stage binary.

The simulator output captured at `/tmp/__TMP_RUN_FILE__` includes a
`# Executed N instructions in M cycles` line — useful as a baseline when
measuring optimization wins.

## Usage Examples

- `run p4plus unit test nic/rudra/src/hydra/p4/p4plus-16/meta_roce/tx/test`
- `run p4plus unit test .../tx/test/test_s2_req_tx_path_sel_fast_path.py`
- `run p4plus unit test .../tx/test -k fast_path -s` — pytest -k filter, -s to see prints
- `ASIC=salina ARCH=x86_64 run p4plus unit test <path>`

## Script

```bash
.claude/skills/scripts/lib/quiet-run.sh p4plus-unit-test \
  .claude/skills/scripts/test/run_p4plus_unit_test.sh <test_path> [pytest_args...]
```

The script auto-detects the `pensando/nic` container by matching the workspace
mount source (via `lib/docker_utils.sh`).

## Defaults

| Env  | Default | Notes |
|---|---|---|
| `ASIC` | `vulcano` | sets `vulsim` vs `salsim` |
| `ARCH` | `riscv`   | matches the sw-emu build output |
| `HYDRA_CONTAINER` | (auto)| explicit override |

`ARCH=riscv` is the right default for tests that consume the `riscv/sim` build
artifacts produced by `build vulcano hydra sw-emu`. For tests that need an
`x86_64/sim` build, pass `ARCH=x86_64`.

## Steps

1. Identify the test path/spec the user wants to run.
2. Run the script directly (these tests are fast — typically <1s per case);
   stream output so the `# Executed N instructions in M cycles` line is visible.
3. If measuring an optimization, capture the insn/cycle counts before and after.

## Conftest expectations

`meta_roce/tx/test/conftest.py` reads `ASIC` and `ARCH` from the environment.
If a sub-tree's `conftest.py` still hardcodes `x86_64`, parameterize it the
same way before running with `ARCH=riscv`.

## Notes

- These are NOT the C++ hydra gtests (use the `gtest` skill for those).
- Each test compiles a tiny C ctl-file at `/tmp/__TMP_CTL_FILE__` and runs
  vulsim/salsim against the per-table `.bin`. Re-running clobbers `/tmp` files.
- Instruction count varies with which d-vec fields are populated and which
  branches are taken — always compare the same test invocation across builds.
