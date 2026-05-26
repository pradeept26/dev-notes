#!/bin/bash
#
# nicctl_utils.sh - Shared utility functions for nicctl operations
#
# This library provides reusable functions for interacting with nicctl
# on remote hosts via SSH.
#

# Function to get card UUID for a specific interface
# Arguments:
#   $1 - node_ip
#   $2 - node_user
#   $3 - node_pass
#   $4 - interface name (e.g., benic1p1)
#   $5 - run_ssh_command function reference (passed as string)
# Returns:
#   Prints card UUID to stdout
#   Returns 0 on success, 1 on failure
function get_card_uuid_for_interface() {
    local ip=$1
    local username=$2
    local password=$3
    local interface=$4
    local ssh_func=${5:-run_ssh_command}

    # Run nicctl show lif and parse the output
    local lif_output
    lif_output=$($ssh_func "$ip" "$username" "$password" "sudo nicctl show lif")

    if [[ $? -ne 0 ]]; then
        return 1
    fi

    # Parse the output to find the card UUID for this interface
    # The output format from nicctl show lif groups LIFs by NIC:
    # NIC : 42424650-5232-3534-3830-303136000000 (0000:06:00.0)
    # ... table header ...
    # 01000070-0100-0000-4242-0490818c7a50    benic1p1    ...
    # We need to find the "NIC :" line before the interface appears
    local card_uuid
    card_uuid=$(echo "$lif_output" | awk -v iface="$interface" '
        /^NIC :/ {
            # Extract the UUID after "NIC :"
            match($0, /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/)
            current_nic = substr($0, RSTART, RLENGTH)
        }
        $0 ~ iface {
            # Found the interface - return the NIC UUID we saw above it
            print current_nic
            exit
        }
    ')

    if [[ -z "$card_uuid" ]]; then
        return 1
    fi

    echo "$card_uuid"
    return 0
}

# Function to get all card UUIDs on a host
# Arguments:
#   $1 - node_ip
#   $2 - node_user
#   $3 - node_pass
#   $4 - run_ssh_command function reference (optional)
# Returns:
#   Prints card UUIDs one per line to stdout
#   Returns 0 on success, 1 on failure
function get_all_card_uuids() {
    local ip=$1
    local username=$2
    local password=$3
    local ssh_func=${4:-run_ssh_command}

    # Run nicctl show card and extract UUIDs
    local card_output
    card_output=$($ssh_func "$ip" "$username" "$password" "sudo nicctl show card")

    if [[ $? -ne 0 ]]; then
        return 1
    fi

    # Extract all UUIDs from the output
    echo "$card_output" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
    return 0
}
