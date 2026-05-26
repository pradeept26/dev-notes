#!/bin/bash
# Run DOL (Day in the Life of) tests inside the pensando/nic container
#
# Usage: ./run_dol.sh [options]
#
# Options:
#   --sub <name>          DOL subset to run (default: rdma_write)
#   --testcase <name>     Run a specific testcase only (optional)
#   --debug               Enable debug logs (WARNING: produces a very large model.log;
#                         only use with a small testcase or subset)
#   --asic <name>         vulcano or salina (default: salina)
#   --p4-program <name>   hydra or pulsar (default: hydra)
#   --dma-mode <name>     DMA mode (default: uxdma)
#   --topo <name>         Topology (default: rdma_hydra)
#   --feature <name>      Feature (default: rdma_hydra)
#   --pipeline <name>     Pipeline (default: rudra)
#   --container <id>      Docker container ID (default: auto-detect)
#
# Environment variables:
#   HYDRA_CONTAINER - Default Docker container ID. Used when --container is not passed
#                     and auto-detection finds zero or multiple containers.
#   HYDRA_SW        - Host workspace path (used in error messages). Defaults to ~/ws/sw/nic.
#
# Examples:
#   ./run_dol.sh                                      # all rdma_write tests, salina hydra
#   ./run_dol.sh --testcase rdma_write_basic          # single testcase
#   ./run_dol.sh --testcase rdma_write_basic --debug  # with debug logs
#   ./run_dol.sh --sub rdma_read                      # different subset

set -e

# Defaults
SUB="rdma_write"
TESTCASE=""
DEBUG=""
ASIC="salina"
P4_PROGRAM="hydra"
DMA_MODE="uxdma"
TOPO="rdma_hydra"
FEATURE="rdma_hydra"
PIPELINE="rudra"
CONTAINER_ID=""

usage() {
    sed -n '2,30p' "$0" | sed 's/^# \?//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --sub)         SUB="$2"; shift 2 ;;
        --testcase)    TESTCASE="$2"; shift 2 ;;
        --debug)       DEBUG="--debug"; shift ;;
        --asic)        ASIC="$2"; shift 2 ;;
        --p4-program)  P4_PROGRAM="$2"; shift 2 ;;
        --dma-mode)    DMA_MODE="$2"; shift 2 ;;
        --topo)        TOPO="$2"; shift 2 ;;
        --feature)     FEATURE="$2"; shift 2 ;;
        --pipeline)    PIPELINE="$2"; shift 2 ;;
        --container)   CONTAINER_ID="$2"; shift 2 ;;
        -h|--help)     usage ;;
        *)             echo "Error: Unknown option '$1'"; usage ;;
    esac
done

# Warn about --debug with broad scope
if [ -n "$DEBUG" ] && [ -z "$TESTCASE" ]; then
    echo "WARNING: --debug enabled without --testcase. This will produce a very large"
    echo "         model.log. Recommend running with --testcase to limit scope."
    echo ""
fi

# Find container if not provided
if [ -z "$CONTAINER_ID" ]; then
    SCRIPT_DIR_DOL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$SCRIPT_DIR_DOL/../lib/docker_utils.sh"
    find_pensando_container || exit 1
fi

# Build the rundol command
RUNDOL_ARGS=(
    --pipeline "$PIPELINE"
    --topo "$TOPO"
    --feature "$FEATURE"
    --nohntap
    --sub "$SUB"
)

if [ -n "$TESTCASE" ]; then
    RUNDOL_ARGS+=(--testcase "$TESTCASE")
fi

if [ -n "$DEBUG" ]; then
    RUNDOL_ARGS+=("$DEBUG")
fi

# Run inside the container.
#
# DOL must run as root inside the container -- it manages /var/log/pensando,
# kills/respawns root-owned processes (qemu-system-riscv64, sal/vul model),
# (re)creates root-owned conf/rudra symlinks under /sw/nic, etc. Running as
# the host user yielded "Permission denied" on rm/ln of those files and
# "Operation not permitted" on kill, leaving the model never fully started
# and the test stalling at "Load P4 via back door". The canonical .job.yml
# (devops/jobs/level1/rudra/vulcano/test/hydra/sim/.job.yml) runs the same
# rundol.sh as root (CI's default container user), so this matches CI.
DOCKER_EXEC="docker exec"
ENV_VARS="PIPELINE=$PIPELINE ASIC=$ASIC P4_PROGRAM=$P4_PROGRAM PCIEMGR_IF=1 DMA_MODE=$DMA_MODE"

# PROFILE differs by ASIC: salina=zephyr, vulcano=qemu
case "$ASIC" in
    salina)  ENV_VARS="$ENV_VARS PROFILE=zephyr" ;;
    vulcano) ENV_VARS="$ENV_VARS PROFILE=qemu" ;;
esac

# Prep steps mirror .job.yml hydra-vulcano-dols target:
#  1. core_count_check.sh -- sanity check on host CPU count
#  2. pull-assets-qemu-rdma -- needed for vulcano (PROFILE=qemu) DOL runs
# Then the actual rundol.sh.
PREP_CMD="ARCH=x86_64 $ENV_VARS PLOG_LEVEL=info ./tools/core_count_check.sh"
if [ "$ASIC" = "vulcano" ]; then
    PREP_CMD="$PREP_CMD && make -C /sw pull-assets-qemu-rdma"
fi
RUNDOL_CMD="$PREP_CMD && $ENV_VARS rudra/test/tools/dol/rundol.sh ${RUNDOL_ARGS[*]}"

# Patterns that mean the test cannot proceed — when seen, kill DOL and exit
FATAL_PATTERNS='PDS global init failed|FATAL ERROR|Segmentation fault'

cleanup_dol() {
    # Best-effort: kill any DOL processes left in the container.
    # Quiet on error (container may be stopped, processes already gone, etc.)
    docker exec "$CONTAINER_ID" \
        pkill -9 -f 'rundol|start-sal-model|start-vul-model|model.bin|capsim|sal_model|qemu-system' \
        >/dev/null 2>&1 || true
}

trap 'cleanup_dol' EXIT INT TERM

LOG_FILE="nic/dol.log"
mkdir -p "$(dirname "$LOG_FILE")"

echo "Running DOL (in /sw/nic): $RUNDOL_CMD"
echo "Logging output to: $LOG_FILE"
echo ""

set -o pipefail
$DOCKER_EXEC -w /sw/nic "$CONTAINER_ID" bash -c "$RUNDOL_CMD" 2>&1 | \
    tee "$LOG_FILE" | \
    while IFS= read -r line; do
        echo "$line"
        if [[ "$line" =~ $FATAL_PATTERNS ]]; then
            echo ""
            echo "FATAL: matched pattern in DOL output — terminating DOL processes"
            cleanup_dol
            exit 1
        fi
    done
EXIT_CODE=${PIPESTATUS[0]}
[ -z "$EXIT_CODE" ] && EXIT_CODE=$?
exit "$EXIT_CODE"
