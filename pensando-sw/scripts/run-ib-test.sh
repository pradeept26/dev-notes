#!/bin/bash
# Simplified IB Benchmark Runner for Pensando Hydra Testing
# Wraps run_ib_bench.py with common test configurations

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default configurations
DEFAULT_USER="ubuntu"
DEFAULT_PASS="amd123"
DEFAULT_ITER=1000
DEFAULT_MODE="hydra"

# SMC configurations
SMC1_IP="10.30.75.198"
SMC2_IP="10.30.75.204"

show_usage() {
    cat <<EOF
${GREEN}Simplified IB Benchmark Runner${NC}

${YELLOW}Usage:${NC}
  $0 <preset> [options]

${YELLOW}Presets:${NC}
  smc1-smc2      Run between SMC1 (server) and SMC2 (client)
  smc2-smc1      Run between SMC2 (server) and SMC1 (client)
  smc1-local     Run local loopback test on SMC1
  smc2-local     Run local loopback test on SMC2
  custom         Custom server/client IPs (use --server and --client)

${YELLOW}Common Options:${NC}
  --qp <num>           Single QP count (e.g., 1, 2, 4, 8, 4094)
  --max-qp <num>       Test powers of 2 up to this (e.g., 16 tests 1,2,4,8,16)
  --iter <num>         Number of iterations (default: 1000)
  --interface <name>   Network interface to use (e.g., benic1p1, benic8p1)
  --direction <uni|bi|both>  Traffic direction (default: uni)
  --write-mode <write|write_with_imm|both>  Write mode (default: write)
  --rcn <enable|disable|both>  RCN mode (default: none)
  --round-robin <1-15>  Round-robin burst value
  --max-msg-size <size>  Max message size (e.g., 8M, 1G)
  --tx-depth <num>     TX depth (-t flag, default: auto)
  --rx-depth <num>     RX depth (-r flag, default: auto)
  --timeout <sec>      Client idle timeout in seconds (default: 600)
  --xlsx               Generate Excel output
  --repeat <num>       Number of test repetitions (default: 1)

${YELLOW}Examples:${NC}
  # Basic test: SMC1→SMC2 with 4 QPs
  $0 smc1-smc2 --qp 4

  # Test specific interface with custom QP and TX/RX depth
  $0 smc1-smc2 --interface benic8p1 --qp 4094 --tx-depth 16 --rx-depth 16 --iter 10

  # Comprehensive: All QPs up to 16, both directions, with Excel
  $0 smc1-smc2 --max-qp 16 --direction both --xlsx

  # Test MSN window: Single QP with large message size
  $0 smc1-smc2 --qp 1 --max-msg-size 8M --direction bi

  # Test with RCN enabled
  $0 smc1-smc2 --qp 8 --rcn enable

  # Local loopback on SMC1
  $0 smc1-local --qp 4

${YELLOW}MSN Context Validation (128-entry window):${NC}
  # Test heavy out-of-order scenarios
  $0 smc1-smc2 --qp 1 --max-msg-size 1M --direction bi --iter 5000

  # Multiple QPs to stress MSN tracking
  $0 smc1-smc2 --max-qp 16 --direction bi --write-mode both

EOF
}

# Parse preset
PRESET="${1:-}"
shift 2>/dev/null || true

case "$PRESET" in
    smc1-smc2)
        SERVER_IP="$SMC1_IP"
        CLIENT_IP="$SMC2_IP"
        ;;
    smc2-smc1)
        SERVER_IP="$SMC2_IP"
        CLIENT_IP="$SMC1_IP"
        ;;
    smc1-local)
        SERVER_IP="$SMC1_IP"
        CLIENT_IP="$SMC1_IP"
        LOCAL_MODE="--local_mode"
        ;;
    smc2-local)
        SERVER_IP="$SMC2_IP"
        CLIENT_IP="$SMC2_IP"
        LOCAL_MODE="--local_mode"
        ;;
    custom)
        # Will be set via --server and --client args
        SERVER_IP=""
        CLIENT_IP=""
        ;;
    -h|--help|help)
        show_usage
        exit 0
        ;;
    "")
        echo -e "${RED}Error: No preset specified${NC}"
        show_usage
        exit 1
        ;;
    *)
        echo -e "${RED}Error: Unknown preset '$PRESET'${NC}"
        show_usage
        exit 1
        ;;
esac

# Parse additional options
QP_ARG=""
ITER_ARG="--num_iter $DEFAULT_ITER"
INTERFACE_ARG=""
DIRECTION_ARG=""
WRITE_MODE_ARG=""
RCN_ARG=""
RR_BURST_ARG=""
MAX_MSG_SIZE_ARG=""
TX_DEPTH_ARG=""
RX_DEPTH_ARG=""
TIMEOUT_ARG=""
XLSX_ARG=""
REPEAT_ARG=""
MODE_ARG="--mode $DEFAULT_MODE"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --qp)
            QP_ARG="--qp_num $2"
            shift 2
            ;;
        --max-qp)
            QP_ARG="--max_qp_num $2"
            shift 2
            ;;
        --iter)
            ITER_ARG="--num_iter $2"
            shift 2
            ;;
        --interface)
            INTERFACE_ARG="--server_intf $2 --client_intf $2"
            shift 2
            ;;
        --direction)
            DIRECTION_ARG="--direction $2"
            shift 2
            ;;
        --write-mode)
            WRITE_MODE_ARG="--write_mode $2"
            shift 2
            ;;
        --rcn)
            RCN_ARG="--rcn $2"
            shift 2
            ;;
        --round-robin)
            RR_BURST_ARG="--round_robin_burst $2"
            shift 2
            ;;
        --max-msg-size)
            MAX_MSG_SIZE_ARG="--max_msg_size $2"
            shift 2
            ;;
        --tx-depth)
            TX_DEPTH_ARG="--tx_depth $2"
            shift 2
            ;;
        --rx-depth)
            RX_DEPTH_ARG="--rx_depth $2"
            shift 2
            ;;
        --timeout)
            TIMEOUT_ARG="--timeout $2"
            shift 2
            ;;
        --xlsx)
            XLSX_ARG="--generate_xlsx"
            shift
            ;;
        --repeat)
            REPEAT_ARG="--repeat $2"
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR_ARG="--output_dir $2"
            shift 2
            ;;
        --timeout)
            TIMEOUT_ARG="--timeout $2"
            shift 2
            ;;
        --server)
            SERVER_IP="$2"
            shift 2
            ;;
        --client)
            CLIENT_IP="$2"
            shift 2
            ;;
        --mode)
            MODE_ARG="--mode $2"
            shift 2
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            show_usage
            exit 1
            ;;
    esac
done

# Validate required parameters
if [[ -z "$SERVER_IP" || -z "$CLIENT_IP" ]]; then
    echo -e "${RED}Error: Server and client IPs required${NC}"
    if [[ "$PRESET" == "custom" ]]; then
        echo "Use: $0 custom --server <IP> --client <IP> [options]"
    fi
    exit 1
fi

# Build command
CMD="python3 /home/pradeept/run_ib_bench.py"
CMD="$CMD --server_ip $SERVER_IP"
CMD="$CMD --client_ip $CLIENT_IP"
CMD="$CMD --username $DEFAULT_USER"
CMD="$CMD --password $DEFAULT_PASS"
CMD="$CMD $MODE_ARG"
CMD="$CMD $ITER_ARG"
[[ -n "$INTERFACE_ARG" ]] && CMD="$CMD $INTERFACE_ARG"
[[ -n "$QP_ARG" ]] && CMD="$CMD $QP_ARG"
[[ -n "$DIRECTION_ARG" ]] && CMD="$CMD $DIRECTION_ARG"
[[ -n "$WRITE_MODE_ARG" ]] && CMD="$CMD $WRITE_MODE_ARG"
[[ -n "$RCN_ARG" ]] && CMD="$CMD $RCN_ARG"
[[ -n "$RR_BURST_ARG" ]] && CMD="$CMD $RR_BURST_ARG"
[[ -n "$MAX_MSG_SIZE_ARG" ]] && CMD="$CMD $MAX_MSG_SIZE_ARG"
[[ -n "$TX_DEPTH_ARG" ]] && CMD="$CMD $TX_DEPTH_ARG"
[[ -n "$RX_DEPTH_ARG" ]] && CMD="$CMD $RX_DEPTH_ARG"
[[ -n "$TIMEOUT_ARG" ]] && CMD="$CMD $TIMEOUT_ARG"
[[ -n "$XLSX_ARG" ]] && CMD="$CMD $XLSX_ARG"
[[ -n "$REPEAT_ARG" ]] && CMD="$CMD $REPEAT_ARG"
[[ -n "$OUTPUT_DIR_ARG" ]] && CMD="$CMD $OUTPUT_DIR_ARG"
[[ -n "$TIMEOUT_ARG" ]] && CMD="$CMD $TIMEOUT_ARG"
[[ -n "$LOCAL_MODE" ]] && CMD="$CMD $LOCAL_MODE"

# Show configuration
echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN}IB Benchmark Configuration${NC}"
echo -e "${GREEN}======================================${NC}"
echo "Server: $SERVER_IP"
echo "Client: $CLIENT_IP"
echo "Mode: $DEFAULT_MODE"
[[ -n "$LOCAL_MODE" ]] && echo "Local Mode: Yes"
echo ""
echo -e "${YELLOW}Command:${NC}"
echo "$CMD"
echo ""
echo -e "${GREEN}======================================${NC}"
echo ""

# Execute
exec $CMD
