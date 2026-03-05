#!/bin/bash
# MSN Context Validation - Comprehensive Test and Statistics Collection
# Compares 128-entry vs 256-entry MSN window performance

set -e

RESULTS_DIR="${1:-msn-validation-results}"
TEST_LABEL="${2:-128msn}"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}MSN Context Validation - Test Label: $TEST_LABEL${NC}"
echo -e "${GREEN}================================================${NC}"
echo ""

# Create results directory
mkdir -p "$RESULTS_DIR/$TEST_LABEL"
cd "$RESULTS_DIR/$TEST_LABEL"

echo -e "${YELLOW}Step 1: Collecting pre-test statistics${NC}"
# Collect pre-test nicctl stats from both SMC1 and SMC2
ssh ubuntu@10.30.75.198 "sudo nicctl show stats -j" > smc1_stats_pre.json
ssh ubuntu@10.30.75.204 "sudo nicctl show stats -j" > smc2_stats_pre.json
ssh ubuntu@10.30.75.198 "sudo nicctl show lif rdma -j" > smc1_rdma_lif_pre.json
ssh ubuntu@10.30.75.204 "sudo nicctl show lif rdma -j" > smc2_rdma_lif_pre.json
echo -e "${GREEN}Pre-test stats collected${NC}"
echo ""

echo -e "${YELLOW}Step 2: Running comprehensive IB tests${NC}"
# Run write tests with QPs up to 64
~/dev-notes/pensando-sw/scripts/run-ib-test.sh smc1-smc2 \
    --max-qp 64 \
    --direction both \
    --write-mode both \
    --xlsx \
    --output-dir .

echo -e "${GREEN}IB tests completed${NC}"
echo ""

echo -e "${YELLOW}Step 3: Collecting post-test statistics${NC}"
# Collect post-test stats
ssh ubuntu@10.30.75.198 "sudo nicctl show stats -j" > smc1_stats_post.json
ssh ubuntu@10.30.75.204 "sudo nicctl show stats -j" > smc2_stats_post.json
ssh ubuntu@10.30.75.198 "sudo nicctl show lif rdma -j" > smc1_rdma_lif_post.json
ssh ubuntu@10.30.75.204 "sudo nicctl show lif rdma -j" > smc2_rdma_lif_post.json

# Collect Hydra-specific stats
ssh ubuntu@10.30.75.198 "sudo nicctl show pipeline rdma qp -j" > smc1_rdma_qp.json 2>/dev/null || echo "QP stats not available"
ssh ubuntu@10.30.75.204 "sudo nicctl show pipeline rdma qp -j" > smc2_rdma_qp.json 2>/dev/null || echo "QP stats not available"
ssh ubuntu@10.30.75.198 "sudo nicctl show pipeline rdma path-stats -j" > smc1_path_stats.json 2>/dev/null || echo "Path stats not available"
ssh ubuntu@10.30.75.204 "sudo nicctl show pipeline rdma path-stats -j" > smc2_path_stats.json 2>/dev/null || echo "Path stats not available"

echo -e "${GREEN}Post-test stats collected${NC}"
echo ""

echo -e "${YELLOW}Step 4: Generating statistics diff${NC}"
# Create simple diff summary
cat > stats_summary.txt <<EOF
=== MSN Context Test Results - Label: $TEST_LABEL ===
Test Date: $(date)

Files Generated:
- IB Test Results: ib_*.xlsx (Excel with charts)
- Pre-test Stats: *_stats_pre.json
- Post-test Stats: *_stats_post.json
- RDMA LIF Stats: *_rdma_lif_*.json
- QP Stats: *_rdma_qp.json
- Path Stats: *_path_stats.json

Key Statistics to Review:
1. RNR (Receiver Not Ready) counters - Should be low/zero
2. MSN-related drops - Check for out-of-window packets
3. Path statistics - Verify no abnormal retransmissions
4. QP creation/deletion - Verify successful operations

Compare these results with baseline (256 MSN) to identify:
- Performance degradation
- Increased drop rates
- RNR threshold hits
EOF

cat stats_summary.txt

echo ""
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}Results saved to: $RESULTS_DIR/$TEST_LABEL/${NC}"
echo -e "${GREEN}================================================${NC}"
