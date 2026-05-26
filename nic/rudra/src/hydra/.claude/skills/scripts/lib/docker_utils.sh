#!/bin/bash
#
# docker_utils.sh - Shared helpers for finding the right pensando/nic container.
#
# Source from a script and call:
#
#   find_pensando_container        # sets CONTAINER_ID, returns 0 / nonzero
#
# Resolution order:
#   1. If $CONTAINER_ID is already set, do nothing.
#   2. If $HYDRA_CONTAINER is set and points to a running container, use it.
#   3. If exactly one pensando/nic container is running, use it.
#   4. If multiple are running, pick the one whose /sw mount source matches
#      the workspace REPO_ROOT (auto-detected by walking up from $PWD looking
#      for `.container_ready` or a `nic/` subdirectory).
#   5. Otherwise, error out with a diagnostic table of the candidate containers
#      and their /sw mount sources.
#

# Walk up from $PWD looking for the workspace root.
# Returns the absolute path on stdout, or empty string if not found.
function _docker_utils_find_repo_root() {
    local d
    d=$(pwd -P)
    while [ "$d" != "/" ]; do
        if [ -e "$d/.container_ready" ] || [ -d "$d/nic" ]; then
            echo "$d"
            return 0
        fi
        d=$(dirname "$d")
    done
    return 1
}

# Print "<id>  <mount_source>" for every running pensando/nic container.
function _docker_utils_list_pensando_with_mounts() {
    docker ps --format "{{.ID}}" | while read -r cid; do
        local img
        img=$(docker inspect "$cid" --format "{{.Config.Image}}" 2>/dev/null)
        if [[ "$img" == "pensando/nic" || "$img" == pensando/nic:* ]]; then
            local mount_src
            mount_src=$(docker inspect "$cid" --format '{{range .Mounts}}{{if eq .Destination "/sw"}}{{.Source}}{{end}}{{end}}' 2>/dev/null)
            printf '%s\t%s\n' "$cid" "$mount_src"
        fi
    done
}

# Set CONTAINER_ID to the right pensando/nic container.
# Returns 0 on success (CONTAINER_ID is set), 1 on failure.
function find_pensando_container() {
    if [ -n "${CONTAINER_ID:-}" ]; then
        return 0
    fi

    local repo_root
    repo_root=$(_docker_utils_find_repo_root || true)
    if [ -n "$repo_root" ]; then
        repo_root=$(readlink -f "$repo_root" 2>/dev/null || echo "$repo_root")
    fi

    local -a entries
    mapfile -t entries < <(_docker_utils_list_pensando_with_mounts)

    # $HYDRA_CONTAINER takes precedence if set and running.
    # Require >= 12 hex chars to avoid prefix collisions with multiple
    # containers (docker's short-id default is 12).
    if [ -n "${HYDRA_CONTAINER:-}" ]; then
        if [[ ! "$HYDRA_CONTAINER" =~ ^[a-f0-9]{12,}$ ]]; then
            echo "Error: \$HYDRA_CONTAINER must be at least 12 hex chars" \
                 "(got '$HYDRA_CONTAINER')." >&2
            return 1
        fi
        local entry cid
        for entry in "${entries[@]}"; do
            cid=${entry%%$'\t'*}
            if [[ "$cid" == "${HYDRA_CONTAINER}"* ]]; then
                CONTAINER_ID="$cid"
                echo "Using \$HYDRA_CONTAINER: $CONTAINER_ID"
                return 0
            fi
        done
        echo "Error: \$HYDRA_CONTAINER=$HYDRA_CONTAINER is not a running pensando/nic container." >&2
        echo "Running pensando/nic containers:" >&2
        printf '  %s\n' "${entries[@]}" >&2
        return 1
    fi

    if [ ${#entries[@]} -eq 0 ]; then
        echo "Error: No running pensando/nic container found." >&2
        echo "Start one with: cd ${repo_root:-${HYDRA_SW:-~/ws/sw}}/nic && make docker/shell" >&2
        return 1
    fi

    if [ ${#entries[@]} -eq 1 ]; then
        CONTAINER_ID=${entries[0]%%$'\t'*}
        echo "Found 1 pensando/nic container: $CONTAINER_ID"
        return 0
    fi

    # Multiple containers — try to match /sw mount source to workspace REPO_ROOT.
    if [ -n "$repo_root" ]; then
        local entry cid mount_src resolved
        for entry in "${entries[@]}"; do
            cid=${entry%%$'\t'*}
            mount_src=${entry#*$'\t'}
            resolved=$(readlink -f "$mount_src" 2>/dev/null || echo "$mount_src")
            if [ "$resolved" = "$repo_root" ]; then
                CONTAINER_ID="$cid"
                echo "Found pensando/nic container matching workspace ($repo_root): $CONTAINER_ID"
                return 0
            fi
        done
    fi

    echo "Error: Found ${#entries[@]} pensando/nic containers; none mount workspace at /sw." >&2
    if [ -n "$repo_root" ]; then
        echo "  workspace: $repo_root" >&2
    fi
    echo "  candidates (id  ->  /sw source):" >&2
    local entry cid mount_src
    for entry in "${entries[@]}"; do
        cid=${entry%%$'\t'*}
        mount_src=${entry#*$'\t'}
        echo "    $cid  ->  ${mount_src:-<none>}" >&2
    done
    echo "" >&2
    echo "Either pass the container ID explicitly, or set \$HYDRA_CONTAINER." >&2
    return 1
}
