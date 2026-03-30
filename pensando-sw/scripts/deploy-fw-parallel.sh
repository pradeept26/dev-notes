#!/bin/bash
# Parallel firmware deployment script for Pensando AINIC systems
# Usage: deploy-fw-parallel.sh <systems> <firmware_tar>
# Example: deploy-fw-parallel.sh smc1,smc2 /sw/ainic_fw_vulcano.tar
#
# System configurations are read dynamically from YAML files in:
#   ~/dev-notes/pensando-sw/hardware/vulcano/data/*.yml
#   ~/dev-notes/pensando-sw/hardware/salina/data/*.yml

set -e

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Directory paths
VULCANO_DIR="$HOME/dev-notes/pensando-sw/hardware/vulcano/data"
SALINA_DIR="$HOME/dev-notes/pensando-sw/hardware/salina/data"

# Associative arrays for system info
declare -A SYSTEM_IPS
declare -A SYSTEM_USERS
declare -A SYSTEM_PASSWORDS

# Function to parse YAML and extract info
load_system_config() {
    local yaml_file=$1
    local system_name=$(basename "$yaml_file" .yml)

    # Extract IP, user, password from YAML
    # For vulcano setups: host.mgmt_ip, credentials.ssh_user, credentials.ssh_password
    # For salina setups: server1.host.mgmt_ip or just host.mgmt_ip

    local ip=$(grep -E '^\s+mgmt_ip:' "$yaml_file" | head -1 | awk '{print $2}')
    local user=$(grep -E '^\s+ssh_user:' "$yaml_file" | head -1 | awk '{print $2}')
    local pass=$(grep -E '^\s+ssh_password:' "$yaml_file" | head -1 | awk '{print $2}')

    if [ -n "$ip" ]; then
        SYSTEM_IPS[$system_name]="$ip"
        SYSTEM_USERS[$system_name]="${user:-ubuntu}"
        SYSTEM_PASSWORDS[$system_name]="${pass:-amd123}"
    fi
}

# Load all system configurations
echo -e "${BLUE}Loading system configurations...${NC}"
if [ -d "$VULCANO_DIR" ]; then
    for yaml_file in "$VULCANO_DIR"/*.yml; do
        [ -f "$yaml_file" ] && load_system_config "$yaml_file"
    done
fi

if [ -d "$SALINA_DIR" ]; then
    for yaml_file in "$SALINA_DIR"/*.yml; do
        [ -f "$yaml_file" ] && load_system_config "$yaml_file"
    done
fi

echo -e "${BLUE}Loaded ${#SYSTEM_IPS[@]} system configurations${NC}"

usage() {
    echo "Usage: $0 <systems> <firmware_tar>"
    echo "       $0 --list"
    echo ""
    echo "Arguments:"
    echo "  systems: comma-separated list (e.g., smc1,smc2)"
    echo "  firmware_tar: path to firmware tarball"
    echo ""
    echo "Options:"
    echo "  --list: Show all available systems with IPs"
    echo ""
    echo "Available systems (${#SYSTEM_IPS[@]} total): ${!SYSTEM_IPS[@]}"
    exit 1
}

list_systems() {
    echo -e "${BLUE}Available Systems:${NC}"
    echo "=================================="
    printf "%-25s %-18s %s\n" "NAME" "IP" "USER"
    echo "=================================="
    for system in $(echo "${!SYSTEM_IPS[@]}" | tr ' ' '\n' | sort); do
        printf "%-25s %-18s %s\n" "$system" "${SYSTEM_IPS[$system]}" "${SYSTEM_USERS[$system]}"
    done
    exit 0
}

# Check for --list option
if [ "$1" == "--list" ]; then
    list_systems
fi

# Check arguments
if [ $# -ne 2 ]; then
    usage
fi

SYSTEMS=$1
FIRMWARE_TAR=$2

# Verify firmware file exists
if [ ! -f "$FIRMWARE_TAR" ]; then
    echo -e "${RED}Error: Firmware file not found: $FIRMWARE_TAR${NC}"
    exit 1
fi

# Get checksum
CHECKSUM=$(md5sum "$FIRMWARE_TAR" | awk '{print $1}')
echo -e "${GREEN}Firmware: $FIRMWARE_TAR${NC}"
echo -e "${GREEN}Checksum: $CHECKSUM${NC}"
echo ""

# Parse systems
IFS=',' read -ra SYSTEM_LIST <<< "$SYSTEMS"

# Function to deploy to a single system
deploy_to_system() {
    local system=$1
    local ip=${SYSTEM_IPS[$system]}
    local user=${SYSTEM_USERS[$system]}
    local pass=${SYSTEM_PASSWORDS[$system]}
    local logfile="/tmp/deploy-${system}-$$.log"

    if [ -z "$ip" ]; then
        echo -e "${RED}[$system] Unknown system (not found in YAML configs)${NC}" | tee "$logfile"
        return 1
    fi

    echo -e "${YELLOW}[$system] Starting deployment to $ip (${user}@${ip})${NC}" | tee "$logfile"

    # Copy firmware
    echo "[$system] Copying firmware..." >> "$logfile"
    if ! sshpass -p "$pass" scp "$FIRMWARE_TAR" ${user}@${ip}:/tmp/ >> "$logfile" 2>&1; then
        echo -e "${RED}[$system] Failed to copy firmware${NC}" | tee -a "$logfile"
        return 1
    fi

    # Verify checksum
    echo "[$system] Verifying checksum..." >> "$logfile"
    REMOTE_CHECKSUM=$(sshpass -p "$pass" ssh ${user}@${ip} "md5sum /tmp/$(basename $FIRMWARE_TAR)" | awk '{print $1}')
    if [ "$CHECKSUM" != "$REMOTE_CHECKSUM" ]; then
        echo -e "${RED}[$system] Checksum mismatch!${NC}" | tee -a "$logfile"
        return 1
    fi

    # Update firmware and reset cards
    echo "[$system] Updating firmware..." >> "$logfile"
    if ! sshpass -p "$pass" ssh ${user}@${ip} \
        "sudo nicctl update firmware -i /tmp/$(basename $FIRMWARE_TAR) && sudo nicctl reset card --all" \
        >> "$logfile" 2>&1; then
        echo -e "${RED}[$system] Firmware update failed${NC}" | tee -a "$logfile"
        return 1
    fi

    # Verify cards (try both vulcano and salina)
    echo "[$system] Verifying cards..." >> "$logfile"
    CARD_COUNT=$(sshpass -p "$pass" ssh ${user}@${ip} "sudo nicctl show card 2>/dev/null | grep -Ec 'vulcano|salina'" || echo "0")

    echo -e "${GREEN}[$system] ✓ Deployment complete - $CARD_COUNT cards detected${NC}" | tee -a "$logfile"

    # Show firmware version
    sshpass -p "$pass" ssh ${user}@${ip} "sudo nicctl show version firmware 2>/dev/null | head -8" >> "$logfile" 2>&1

    return 0
}

# Deploy to all systems in parallel
pids=()
logfiles=()

for system in "${SYSTEM_LIST[@]}"; do
    deploy_to_system "$system" &
    pids+=($!)
    logfiles+=("/tmp/deploy-${system}-$$.log")
done

# Wait for all deployments to complete
echo ""
echo "Deploying to ${#SYSTEM_LIST[@]} systems in parallel..."
echo ""

failed=0
for i in "${!pids[@]}"; do
    if wait ${pids[$i]}; then
        : # Success - already logged
    else
        failed=$((failed + 1))
    fi
done

# Summary
echo ""
echo "========================================"
echo "Deployment Summary"
echo "========================================"

for system in "${SYSTEM_LIST[@]}"; do
    logfile="/tmp/deploy-${system}-$$.log"
    if [ -f "$logfile" ]; then
        echo ""
        echo "--- $system ---"
        tail -5 "$logfile"
    fi
done

echo ""
if [ $failed -eq 0 ]; then
    echo -e "${GREEN}✓ All deployments successful!${NC}"
    exit 0
else
    echo -e "${RED}✗ $failed deployment(s) failed${NC}"
    echo "Check logs in /tmp/deploy-*.log for details"
    exit 1
fi
