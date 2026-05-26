---
name: qemu-test
description: Launch QEMU vulcano sim and run RDMA perftest in the guest VM
triggers:
  - qemu test
  - launch qemu
  - run qemu perftest
  - qemu start
  - qemu setup
  - qemu teardown
---

# QEMU Test Skill

Launch a QEMU-based vulcano hydra simulation and run RDMA perftest from a
guest Linux VM against the simulated NIC. Runs inside the `pensando/nic`
container, mirroring the CI flow at
`devops/jobs/level1/rudra/vulcano/test/hydra/sim/hydra-vulcano-qemu-system-test.sh`
but split into developer-friendly subcommands.

## Usage Examples

- "qemu setup"
- "launch qemu"
- "launch qemu with p4debug"
- "run qemu perftest"
- "qemu teardown"
- "qemu test all" (setup + start + test, leaves VM up)

## Actions

| Action     | What it does                                                              | When to use                       |
|------------|---------------------------------------------------------------------------|-----------------------------------|
| `setup`    | ssh-keygen (idempotent), `make pull-assets-qemu-rdma-img`, copy device json | Once per fresh container          |
| `start`    | `launch_qemu.py ... start --p4-loader=flash --loopback examine`           | After `setup`, brings up the VM   |
| `test`     | Build drivers, scp to VM, run `<TEST>-test.sh`                            | After `start`, runs perftest      |
| `teardown` | `launch_qemu.py ... teardown`                                             | When done, stops QEMU             |
| `all`      | `setup` → `start` → `test` (no teardown)                                  | End-to-end one-shot               |

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `--asic` | `vulcano` | Pass-through to `launch_qemu.py` (only vulcano supported) |
| `--p4-program` | `hydra` | `hydra` or `pulsar` |
| `--test` | `default` | Selects `<name>-test.sh` for the `test` action |
| `--p4-loader` | `flash` | `flash` / `backdoor` / `none` — passed to `start` |
| `--model-debug` | `none` | `none` (default) / `p4debug` (less verbose, P4-only traces) / `debug` (very verbose — all model traces). Only applied to `start`. |
| `--no-tmux` | (off) | Use `--multiplexer subprocess` instead of `tmux` for `start`/`teardown`. Default for dev is tmux so you can `tmux attach -t vulcano-$USER` from inside the container; pass `--no-tmux` for CI-style headless runs. |
| `--container` | (auto) | Docker container ID |

## Script

Run via `quiet-run.sh` so the noisy launch_qemu / drivers-linux / perftest
output goes to `/tmp/claude-skills/qemu-<action>-*.log` instead of dumped
into the conversation. Read the log to inspect failures. The `teardown`
action is short — call it directly without the wrapper.

```bash
# setup, start, test, all — wrap with quiet-run
.claude/skills/scripts/lib/quiet-run.sh qemu-<action> \
  .claude/skills/scripts/test/run_qemu_test.sh <action> [options]

# teardown — call directly
.claude/skills/scripts/test/run_qemu_test.sh teardown [options]
```

## Steps

1. Parse user request to identify the action and any flags (`--model-debug`, `--test`).
2. **Container selection**: script auto-detects `pensando/nic` containers.
   - If exactly one is running → use it.
   - If multiple → use `$HYDRA_CONTAINER` if set; otherwise **ask the user which one to use** before running.
3. Warn the user if they request `--model-debug debug` (large logs).
4. Run the script via `quiet-run.sh` (except `teardown`).

## Equivalent direct commands

The skill wraps these commands (all run inside the container at `/sw`):

```bash
# setup
ssh-keygen -t ed25519 -P "" -f ~/.ssh/id_ed25519     # only if missing
make -C /sw pull-assets-qemu-rdma-img
mkdir -p /sw/nic/conf/gen/
cp /sw/nic/rudra/src/conf/hydra/vulcano/device-pf1-coredev-llc-dol.json \
   /sw/nic/conf/gen/fdt_output.json

# start
/sw/tools/scripts/launch_qemu.py --asic vulcano --p4-program hydra \
    --verbose --multiplexer tmux --no-docker \
    start --p4-loader=flash --loopback examine
# (with --model-debug p4debug appended if requested)

# test
PIPELINE=rudra P4_PROGRAM=hydra /sw/platform/tools/drivers-linux.sh
# (then vm_scp drivers + vm-scripts + rdma-unit-test, run <TEST>-test.sh)

# teardown
/sw/tools/scripts/launch_qemu.py --asic vulcano --p4-program hydra \
    --verbose --multiplexer tmux --no-docker teardown
# (followed by `sudo pkill -9 -f "qemu-system|sal_model|model_sim_cli|simbridge|relay\.py"`
#  as a belt-and-suspenders fallback)
```

## Notes

- **Pre-req**: a successful `build vulcano hydra sw-emu` must have produced the
  model + zephyr artifacts under `/sw/nic/build/{x86_64,riscv}/sim/...`.
  The skill does NOT unpack the CI tarballs (`build_vulcano_model.tar.gz`,
  `zephyr_vulcano_sw_emu.tar.gz`) — those only exist in CI.
- The guest VM is reachable at `ubuntu@localhost:1037` (port hardcoded by
  `launch_qemu.py`). After `start` you can `ssh -p 1037 -i ~/.ssh/id_ed25519
  ubuntu@localhost` from inside the container for manual testing.
- With the default tmux multiplexer, attach to the QEMU windows from inside
  the container with `tmux attach -t ${USER}_qemu` (session name is
  `<user>_qemu`, hardcoded by `launch_qemu.py`). Windows include the RISC-V
  model, the x86 host VM console, telnet to the host monitor, etc. Use
  `--no-tmux` to skip tmux (CI-style headless).
- `setup` is idempotent and safe to re-run (skips ssh-keygen if the key exists;
  asset pulls are no-ops when cached).
- `--model-debug debug` produces very large traces; prefer `p4debug` unless you
  specifically need non-P4 model traces.
- If `start` fails early with `Segmentation fault`, `FATAL ERROR`, a `qemu-system`
  error, or a Python traceback from `launch_qemu.py`, the script kills any
  running QEMU/model processes in the container and exits non-zero.
