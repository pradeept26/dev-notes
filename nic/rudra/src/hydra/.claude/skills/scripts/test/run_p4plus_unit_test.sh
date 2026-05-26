#!/bin/bash
# run_mputest.sh - Run a P4+ mputest pytest inside the pensando/nic container.
#
# Usage:
#   ./run_mputest.sh <test_path> [pytest_args...]
#
# Arguments:
#   test_path    - File, directory, or pytest node-id, relative to the workspace
#                  root (e.g. nic/rudra/src/hydra/p4/p4plus-16/meta_roce/tx/test
#                  or that directory plus ::TestClass::test_method).
#   pytest_args  - Forwarded verbatim to py.test (e.g. -v -s -k name).
#
# Environment:
#   ASIC          - vulcano (default) | salina
#   ARCH          - riscv (default; matches the sw-emu build) | x86_64
#   HYDRA_CONTAINER - explicit container ID; otherwise auto-detected.
#

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <test_path> [pytest_args...]" >&2
    echo "Example: $0 nic/rudra/src/hydra/p4/p4plus-16/meta_roce/tx/test -v -s" >&2
    exit 1
fi

TEST_PATH="$1"
shift
PYTEST_ARGS=("$@")

ASIC=${ASIC:-vulcano}
ARCH=${ARCH:-riscv}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/docker_utils.sh"
find_pensando_container || exit 1

# Resolve workdir: if test_path points at a directory, cd into it; else cd into
# its parent so the relative test-id resolves correctly.
container_path="/sw/${TEST_PATH#/}"
container_path="${container_path#/sw/sw/}"  # in case caller already prefixed /sw/
# Strip pytest node-id suffix (anything after :: -- pytest can take it as an arg).
node_path="${container_path%%::*}"
if [[ "$node_path" == "$container_path" ]]; then
    pytest_target="$(basename "$container_path")"
else
    pytest_target="$(basename "$node_path")::${container_path#*::}"
fi

# Working directory: dirname of the file (or the dir itself).
if docker exec "$CONTAINER_ID" test -d "$node_path"; then
    workdir="$node_path"
    pytest_target="."
else
    workdir="$(dirname "$node_path")"
fi

echo "Container: $CONTAINER_ID"
echo "Workdir:   $workdir"
echo "Target:    $pytest_target  (ASIC=$ASIC ARCH=$ARCH)"
echo ""

exec docker exec -u "$(id -u):$(id -g)" -w "$workdir" "$CONTAINER_ID" \
    bash -c "ASIC=$ASIC ARCH=$ARCH py.test ${pytest_target@Q} ${PYTEST_ARGS[@]@Q}"
