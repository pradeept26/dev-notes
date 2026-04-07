#!/bin/bash
# Parallel health check for Waco3-8 cluster
# Checks both host-level (SSH) and console-level (telnet) health

SETUPS="waco3 waco4 waco5 waco6 waco7 waco8"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_DIR="/tmp/waco_health_check_${TIMESTAMP}"

mkdir -p "$LOG_DIR"

# Function to check one Waco system
check_waco_health() {
    local setup=$1
    local log_file="${LOG_DIR}/${setup}.log"

    echo "=== Health Check for ${setup} at $(date) ===" | tee "$log_file"

    # Get management IP from YAML using Python
    local yaml_file="${SCRIPT_DIR}/../hardware/vulcano/data/${setup}.yml"
    local mgmt_ip=$(python3 -c "import yaml; data = yaml.safe_load(open('${yaml_file}')); print(data['host']['mgmt_ip'])" 2>/dev/null)

    if [[ -z "$mgmt_ip" ]]; then
        echo "❌ Failed to get management IP from YAML: ${yaml_file}" | tee -a "$log_file"
        return 1
    fi

    # --- HOST CHECKS (via SSH) ---
    echo -e "\n[HOST CHECKS via SSH to ${mgmt_ip}]" | tee -a "$log_file"

    # Check 1: SSH connectivity
    if ! ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no ubuntu@${mgmt_ip} "echo SSH OK" &>> "$log_file"; then
        echo "❌ SSH FAILED to ${mgmt_ip}" | tee -a "$log_file"
        return 1
    fi
    echo "✅ SSH connectivity OK" | tee -a "$log_file"

    # Check 2: Card count (expect 8)
    local card_count=$(ssh -o StrictHostKeyChecking=no ubuntu@${mgmt_ip} "sudo nicctl show card -j 2>/dev/null | jq '. | length'" 2>/dev/null)
    if [[ "$card_count" == "8" ]]; then
        echo "✅ Card count: 8/8" | tee -a "$log_file"
    else
        echo "❌ Card count: ${card_count}/8" | tee -a "$log_file"
    fi

    # Check 3: Firmware version (show all versions)
    echo -e "\nFirmware versions:" | tee -a "$log_file"
    ssh -o StrictHostKeyChecking=no ubuntu@${mgmt_ip} "sudo nicctl show version 2>&1" &>> "$log_file"

    # Check 4: RDMA devices
    local rdma_count=$(ssh -o StrictHostKeyChecking=no ubuntu@${mgmt_ip} "ibv_devices 2>/dev/null | grep -c 'ai'" 2>/dev/null)
    if [[ "$rdma_count" == "8" ]]; then
        echo "✅ RDMA devices: 8/8" | tee -a "$log_file"
    else
        echo "⚠️  RDMA devices: ${rdma_count}/8" | tee -a "$log_file"
    fi

    # Check 5: PCIe devices
    local pcie_count=$(ssh -o StrictHostKeyChecking=no ubuntu@${mgmt_ip} "lspci 2>/dev/null | grep -c Pensando" 2>/dev/null)
    if [[ "$pcie_count" == "8" ]]; then
        echo "✅ PCIe devices: 8/8" | tee -a "$log_file"
    else
        echo "❌ PCIe devices: ${pcie_count}/8" | tee -a "$log_file"
    fi

    # --- CONSOLE CHECKS (via console-mgr.py) ---
    echo -e "\n[CONSOLE CHECKS via console-mgr.py]" | tee -a "$log_file"

    # Check 6: Vulcano console firmware versions
    echo -e "\nVulcano consoles (all 8 NICs):" | tee -a "$log_file"
    python3 "${SCRIPT_DIR}/console-mgr.py" --setup ${setup} --console vulcano --all version &>> "$log_file"
    if [[ $? -eq 0 ]]; then
        echo "✅ Vulcano consoles accessible" | tee -a "$log_file"
    else
        echo "❌ Vulcano console errors (check log)" | tee -a "$log_file"
    fi

    # Check 7: SuC console accessibility
    echo -e "\nSuC consoles (all 8 NICs):" | tee -a "$log_file"
    python3 "${SCRIPT_DIR}/console-mgr.py" --setup ${setup} --console suc --all uptime &>> "$log_file"
    if [[ $? -eq 0 ]]; then
        echo "✅ SuC consoles accessible" | tee -a "$log_file"
    else
        echo "⚠️  SuC console errors (check log)" | tee -a "$log_file"
    fi

    echo -e "\n=== Health check complete for ${setup} ===" | tee -a "$log_file"
}

# Export function for parallel execution
export -f check_waco_health
export SCRIPT_DIR LOG_DIR

# Launch parallel health checks (one per Waco system)
echo "========================================="
echo "Waco3-8 Cluster Health Check"
echo "========================================="
echo "Starting parallel health checks for: ${SETUPS}"
echo "Logs will be saved to: ${LOG_DIR}"
echo ""

# Use GNU parallel if available, otherwise xargs
if command -v parallel &> /dev/null; then
    echo "$SETUPS" | tr ' ' '\n' | parallel -j 6 check_waco_health {}
else
    echo "$SETUPS" | tr ' ' '\n' | xargs -P 6 -I {} bash -c 'check_waco_health "$@"' _ {}
fi

# Wait for all background processes to complete
wait

# Generate summary report
echo ""
echo "========================================="
echo "HEALTH CHECK SUMMARY"
echo "========================================="
for setup in $SETUPS; do
    echo ""
    echo "[$setup]"
    if [[ -f "${LOG_DIR}/${setup}.log" ]]; then
        grep -E "(✅|❌|⚠️)" "${LOG_DIR}/${setup}.log" || echo "  No health indicators found"
    else
        echo "  ❌ Log file not found"
    fi
done

echo ""
echo "========================================="
echo "Detailed logs available at: ${LOG_DIR}/"
echo "========================================="
echo ""
echo "To view a specific log:"
echo "  cat ${LOG_DIR}/waco3.log"
echo ""
