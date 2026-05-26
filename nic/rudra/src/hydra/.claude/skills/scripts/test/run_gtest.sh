#!/bin/bash
# Run hydra gtest tests inside the pensando/nic container.
#
# Wraps `rudra/test/tools/run_ionic_gtest.sh` (which itself drives setup_dol.sh
# in --debug mode, so a model.log is always produced under /sw/nic/).
#
# Usage: ./run_gtest.sh [options]
#
# Options:
#   --testcase <pattern>  gtest filter pattern (--gtest_filter=); default: '-*scale*'
#                         Examples:
#                           --testcase 'IPv4/resp_rx.write_only_verify_payload_and_ack/0'
#                           --testcase '*resp_rx*'
#                           --testcase '-*scale*'   (exclude scale tests, the .job.yml default)
#   --asic <name>         vulcano or salina (default: vulcano)
#   --p4-program <name>   hydra or pulsar (default: hydra)
#   --dma-mode <name>     DMA mode (default: uxdma)
#   --aq                  Use the AQ gtest binary (hydra_gtest_aq) instead of hydra_gtest
#   --container <id>      Docker container ID (default: auto-detect)
#
# Environment:
#   HYDRA_CONTAINER  - default container ID when --container is omitted and detection
#                      finds zero or multiple matches.
#
# DOL setup_dol.sh is invoked with --debug already (hardcoded in
# rudra/test/tools/run_ionic_gtest.sh:36), so per-action /sw/nic/model.log is
# captured for every gtest run. Pair with `nic/tools/parse.py` inside the
# container to produce an annotated /sw/nic/model1.log:
#     ./tools/parse.py --model-log /sw/nic/model.log
#
# Examples:
#   ./run_gtest.sh                                                 # full default suite
#   ./run_gtest.sh --testcase 'IPv4/resp_rx.write_only_verify_payload_and_ack/0'
#   ./run_gtest.sh --testcase '*req_tx*' --aq

set -e

TESTCASE="-*scale*"
ASIC="vulcano"
P4_PROGRAM="hydra"
DMA_MODE="uxdma"
USE_AQ=0
CONTAINER_ID=""

usage() {
    sed -n '2,30p' "$0" | sed 's/^# \?//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --testcase)    TESTCASE="$2"; shift 2 ;;
        --asic)        ASIC="$2"; shift 2 ;;
        --p4-program)  P4_PROGRAM="$2"; shift 2 ;;
        --dma-mode)    DMA_MODE="$2"; shift 2 ;;
        --aq)          USE_AQ=1; shift ;;
        --container)   CONTAINER_ID="$2"; shift 2 ;;
        -h|--help)     usage ;;
        *)             echo "Error: Unknown option '$1'"; usage ;;
    esac
done

# Container auto-detect.
if [ -z "$CONTAINER_ID" ]; then
    SCRIPT_DIR_GT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$SCRIPT_DIR_GT/../lib/docker_utils.sh"
    find_pensando_container || exit 1
fi

# Pick gtest binary
if [ "$USE_AQ" = 1 ]; then
    GTEST_BIN_NAME="hydra_gtest_aq"
else
    GTEST_BIN_NAME="hydra_gtest"
fi
GTEST_BINARY="/sw/nic/rudra/build/${P4_PROGRAM}/x86_64/sim/rudra/${ASIC}/bin/${GTEST_BIN_NAME}"

# PROFILE differs by ASIC (matches .job.yml hydra-vulcano-gtest target)
case "$ASIC" in
    vulcano) PROFILE="qemu" ;;
    salina)  PROFILE="zephyr" ;;
esac

# Prep steps mirror .job.yml hydra-vulcano-gtest target:
#   sudo core_count_check.sh && pull-assets-qemu-rdma && run_ionic_gtest.sh
# We run as root inside the container (no -u $USER on docker exec), same
# reasoning as run_dol.sh: setup_dol.sh manages root-owned files and processes
# under /sw/nic, /var/log/pensando, etc., and was failing with "Permission
# denied" / "Operation not permitted" when run as a non-root user.
PREP_CMD="ARCH=x86_64 PIPELINE=rudra ASIC=$ASIC P4_PROGRAM=$P4_PROGRAM PCIEMGR_IF=1 DMA_MODE=$DMA_MODE PROFILE=$PROFILE PLOG_LEVEL=info ./tools/core_count_check.sh"
if [ "$ASIC" = "vulcano" ]; then
    PREP_CMD="$PREP_CMD && make -C /sw pull-assets-qemu-rdma"
fi

# run_ionic_gtest.sh consumes GTEST_FILTER (see its line 53).
RUN_CMD="DMA_MODE=$DMA_MODE ASIC=$ASIC P4_PROGRAM=$P4_PROGRAM GTEST_BINARY=$GTEST_BINARY GTEST_FILTER='$TESTCASE' PROFILE=$PROFILE LOG_FILE=hydra_gtest.log rudra/test/tools/run_ionic_gtest.sh"

FULL_CMD="cd /sw/nic && $PREP_CMD && $RUN_CMD"

cleanup_gtest() {
    docker exec "$CONTAINER_ID" \
        pkill -9 -f 'run_ionic_gtest|start-vul-model|qemu-system|sal_model|vul_model|capsim|hydra_gtest' \
        >/dev/null 2>&1 || true
}
trap 'cleanup_gtest' EXIT INT TERM

echo "Running gtest in container $CONTAINER_ID"
echo "Filter: $TESTCASE"
echo "Binary: $GTEST_BINARY"
echo ""

set -o pipefail
docker exec "$CONTAINER_ID" bash -c "$FULL_CMD" 2>&1
