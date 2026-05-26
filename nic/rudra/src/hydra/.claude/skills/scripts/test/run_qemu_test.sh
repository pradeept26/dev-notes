#!/bin/bash
# Launch QEMU sim and run RDMA perftest inside the pensando/nic container.
#
# Wraps tools/scripts/launch_qemu.py + the host/vm test flow under
# devops/jobs/level1/rudra/vulcano/test/hydra/sim/. Assumes the sw-emu
# build artifacts are already in-place (run `build vulcano hydra sw-emu`
# first) — does NOT unpack the CI tarballs.
#
# Usage: ./run_qemu_test.sh <action> [options]
#
# Actions:
#   setup       One-shot: ssh-keygen (idempotent), pull qemu/rdma assets,
#               copy device fdt json. Run once per fresh container.
#   start       Launch QEMU via launch_qemu.py.
#   test        Build drivers, scp to VM, run <TEST>-test.sh on the host
#               (which vm-ssh's into the guest VM to run perftest).
#   teardown    Stop QEMU and clean up.
#   all         setup -> start -> test (no teardown — VM left up).
#
# Options:
#   --asic <name>           vulcano (default; only vulcano supported)
#   --p4-program <name>     hydra (default) or pulsar
#   --test <name>           Test variant for the `test` action (default: default)
#                           Selects devops/.../<name>-test.sh
#   --p4-loader <mode>      flash (default) | backdoor | none — passed to start
#   --model-debug <mode>    none (default) | p4debug (less verbose) |
#                           debug (very verbose, large logs) — passed to start
#   --no-tmux               Use --multiplexer subprocess instead of tmux for
#                           start/teardown (CI-style; no attachable session).
#                           Default for dev is tmux so you can `tmux attach`.
#   --container <id>        Docker container ID (default: auto-detect)
#
# Environment variables:
#   HYDRA_CONTAINER  Default Docker container ID. Used when --container is not
#                    passed and auto-detection finds zero or multiple containers.
#   HYDRA_SW         Host workspace path (used in error messages). Defaults to ~/ws/sw/nic.
#
# Examples:
#   ./run_qemu_test.sh setup
#   ./run_qemu_test.sh start
#   ./run_qemu_test.sh start --model-debug p4debug
#   ./run_qemu_test.sh test
#   ./run_qemu_test.sh teardown
#   ./run_qemu_test.sh all

set -e

# Defaults
ACTION=""
ASIC="vulcano"
P4_PROGRAM="hydra"
TEST_NAME="default"
P4_LOADER="flash"
MODEL_DEBUG="none"
MULTIPLEXER="tmux"
CONTAINER_ID=""

usage() {
    sed -n '2,44p' "$0" | sed 's/^# \?//'
    exit 1
}

if [ $# -lt 1 ]; then
    usage
fi

ACTION="$1"; shift

case "$ACTION" in
    setup|start|test|teardown|all) ;;
    -h|--help) usage ;;
    *) echo "Error: Unknown action '$ACTION'"; usage ;;
esac

while [[ $# -gt 0 ]]; do
    case $1 in
        --asic)         ASIC="$2"; shift 2 ;;
        --p4-program)   P4_PROGRAM="$2"; shift 2 ;;
        --test)         TEST_NAME="$2"; shift 2 ;;
        --p4-loader)    P4_LOADER="$2"; shift 2 ;;
        --model-debug)  MODEL_DEBUG="$2"; shift 2 ;;
        --no-tmux)      MULTIPLEXER="subprocess"; shift ;;
        --container)    CONTAINER_ID="$2"; shift 2 ;;
        -h|--help)      usage ;;
        *) echo "Error: Unknown option '$1'"; usage ;;
    esac
done

case "$MODEL_DEBUG" in
    none|p4debug|debug) ;;
    *) echo "Error: --model-debug must be one of: none, p4debug, debug"; exit 1 ;;
esac

if [ "$MODEL_DEBUG" = "debug" ]; then
    echo "WARNING: --model-debug debug produces very verbose model traces."
    echo "         Expect large logs; use only when actively debugging."
    echo ""
fi

# Find container if not provided
if [ -z "$CONTAINER_ID" ]; then
    SCRIPT_DIR_QT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$SCRIPT_DIR_QT/../lib/docker_utils.sh"
    find_pensando_container || exit 1
fi

DOCKER_EXEC="docker exec -u $USER -e USER=$USER"

# Run a command string inside the container with the given working dir.
in_container() {
    local cwd="$1"; shift
    $DOCKER_EXEC -w "$cwd" "$CONTAINER_ID" bash -c "$*"
}

# Patterns that indicate the run cannot proceed — match → kill QEMU and exit.
FATAL_PATTERNS='Segmentation fault|FATAL ERROR|qemu-system.*: error|launch_qemu\.py.*Traceback'

cleanup_qemu() {
    docker exec -u "$USER" "$CONTAINER_ID" \
        pkill -9 -f 'launch_qemu\.py|qemu-system|sal_model|model_sim_cli' \
        >/dev/null 2>&1 || true
}

watch_for_fatal() {
    # Reads stdin, echoes each line, and triggers cleanup_qemu + nonzero exit
    # on FATAL_PATTERNS match. Used for `start` and `test` where early failure
    # should be surfaced quickly.
    while IFS= read -r line; do
        echo "$line"
        if [[ "$line" =~ $FATAL_PATTERNS ]]; then
            echo ""
            echo "FATAL: matched pattern in QEMU output — terminating processes"
            cleanup_qemu
            exit 1
        fi
    done
}

# ---------- actions ----------

do_setup() {
    echo "=== qemu-test: setup ==="
    # ssh-keygen — idempotent (skip if key exists). The CI script does not guard;
    # we do, so devs can re-run setup safely.
    in_container /sw '
        if [ ! -f ~/.ssh/id_ed25519 ]; then
            mkdir -p ~/.ssh
            ssh-keygen -t ed25519 -P "" -f ~/.ssh/id_ed25519
        else
            echo "ssh key already present at ~/.ssh/id_ed25519, skipping keygen"
        fi
    '
    in_container /sw 'make pull-assets-qemu-rdma-img'
    in_container /sw '
        mkdir -p /sw/nic/conf/gen/
        cp /sw/nic/rudra/src/conf/hydra/vulcano/device-pf1-coredev-llc-dol.json \
           /sw/nic/conf/gen/fdt_output.json
    '
}

do_start() {
    echo "=== qemu-test: start ==="
    local debug_arg=""
    if [ "$MODEL_DEBUG" != "none" ]; then
        debug_arg="--model-debug=$MODEL_DEBUG"
    fi
    set -o pipefail
    in_container /sw "
        /sw/tools/scripts/launch_qemu.py \
            --asic $ASIC --p4-program $P4_PROGRAM \
            --verbose --multiplexer $MULTIPLEXER --no-docker \
            start --p4-loader=$P4_LOADER $debug_arg --loopback examine
    " 2>&1 | watch_for_fatal
}

do_test() {
    echo "=== qemu-test: test ($TEST_NAME) ==="
    local testdir="/sw/devops/jobs/level1/rudra/vulcano/test/hydra/sim"
    set -o pipefail
    in_container /sw "
        set -euxo pipefail
        cd $testdir
        source host-funcs.sh
        PIPELINE=rudra P4_PROGRAM=$P4_PROGRAM /sw/platform/tools/drivers-linux.sh
        ls -l /sw/platform/gen/drivers-linux.tar.xz
        vm_scp -r /sw/platform/{make,tools/edma_ex_app} VM:
        vm_scp /sw/platform/gen/drivers-linux.tar.xz VM:
        vm_scp $testdir/vm-scripts/* VM:
        vm_scp -r /sw/nic/third-party/rdma-unit-test VM:
        $testdir/${TEST_NAME}-test.sh
    " 2>&1 | watch_for_fatal
}

do_teardown() {
    echo "=== qemu-test: teardown ==="
    # launch_qemu.py teardown handles tmux session destruction (when started
    # with --multiplexer tmux) and root-owned file cleanup. It does NOT kill
    # orphaned QEMU procs reliably (especially in subprocess mode), so we
    # follow up with a sudo pkill as a belt-and-suspenders cleanup.
    in_container /sw "
        /sw/tools/scripts/launch_qemu.py \
            --asic $ASIC --p4-program $P4_PROGRAM \
            --verbose --multiplexer $MULTIPLEXER --no-docker \
            teardown
    " || echo "(launch_qemu.py teardown returned non-zero; continuing with pkill fallback)"
    in_container /sw '
        sudo pkill -9 -f "qemu-system-(riscv64|x86_64)" 2>/dev/null || true
        sudo pkill -9 -f "sal_model|model_sim_cli|simbridge" 2>/dev/null || true
        sudo pkill -9 -f "relay\.py" 2>/dev/null || true
        echo "qemu/model procs after pkill:"
        ps -ef | grep -E "qemu-system|sal_model|model_sim_cli|simbridge|relay\.py" | grep -v defunct | grep -v grep || echo "  (none)"
    '
}

case "$ACTION" in
    setup)    do_setup ;;
    start)    do_start ;;
    test)     do_test ;;
    teardown) do_teardown ;;
    all)
        do_setup
        do_start
        do_test
        ;;
esac
