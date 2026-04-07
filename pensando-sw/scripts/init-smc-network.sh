#!/bin/bash
# Initialize SMC Network Configuration for IB/RDMA Testing
# Configures routes between SMC1 and SMC2 for cross-host connectivity

set -e

SMC_HOST="${1:-}"

if [[ -z "$SMC_HOST" ]]; then
    echo "Usage: $0 <smc1|smc2|both>"
    echo ""
    echo "Examples:"
    echo "  $0 smc1      # Configure SMC1 only"
    echo "  $0 smc2      # Configure SMC2 only"
    echo "  $0 both      # Configure both SMC1 and SMC2"
    exit 1
fi

configure_smc1() {
    echo "=== Configuring SMC1 (10.30.75.198) ==="

    # SMC1 has IPs: 30.1.x.1, needs to reach SMC2: 30.2.x.1
    # Gateway for 30.2.x.0/24 networks is 30.1.1.2

    sshpass -p amd123 ssh ubuntu@10.30.75.198 <<'EOF'
# Add routes to reach SMC2's networks via gateway 30.1.1.2
sudo ip route add 30.2.1.0/24 via 30.1.1.2 dev benic1p1 2>/dev/null || echo "Route 30.2.1.0/24 already exists"
sudo ip route add 30.2.2.0/24 via 30.1.2.2 dev benic2p1 2>/dev/null || echo "Route 30.2.2.0/24 already exists"
sudo ip route add 30.2.3.0/24 via 30.1.3.2 dev benic3p1 2>/dev/null || echo "Route 30.2.3.0/24 already exists"
sudo ip route add 30.2.4.0/24 via 30.1.4.2 dev benic4p1 2>/dev/null || echo "Route 30.2.4.0/24 already exists"
sudo ip route add 30.2.5.0/24 via 30.1.5.2 dev benic5p1 2>/dev/null || echo "Route 30.2.5.0/24 already exists"
sudo ip route add 30.2.6.0/24 via 30.1.6.2 dev benic6p1 2>/dev/null || echo "Route 30.2.6.0/24 already exists"
sudo ip route add 30.2.7.0/24 via 30.1.7.2 dev benic7p1 2>/dev/null || echo "Route 30.2.7.0/24 already exists"
sudo ip route add 30.2.8.0/24 via 30.1.8.2 dev benic8p1 2>/dev/null || echo "Route 30.2.8.0/24 already exists"

# Verify routes
echo "=== SMC1 Routes to SMC2 ==="
ip route | grep "30.2"

# Test ping to SMC2's first interface
echo "=== Testing connectivity to SMC2 (30.2.1.1) ==="
ping -c 3 30.2.1.1
EOF

    echo "SMC1 configuration complete"
}

configure_smc2() {
    echo "=== Configuring SMC2 (10.30.75.204) ==="

    # SMC2 has IPs: 30.2.x.1, needs to reach SMC1: 30.1.x.1
    # Gateway for 30.1.x.0/24 networks is 30.2.x.2

    sshpass -p amd123 ssh ubuntu@10.30.75.204 <<'EOF'
# Add routes to reach SMC1's networks via gateway 30.2.x.2
sudo ip route add 30.1.1.0/24 via 30.2.1.2 dev benic1p1 2>/dev/null || echo "Route 30.1.1.0/24 already exists"
sudo ip route add 30.1.2.0/24 via 30.2.2.2 dev benic2p1 2>/dev/null || echo "Route 30.1.2.0/24 already exists"
sudo ip route add 30.1.3.0/24 via 30.2.3.2 dev benic3p1 2>/dev/null || echo "Route 30.1.3.0/24 already exists"
sudo ip route add 30.1.4.0/24 via 30.2.4.2 dev benic4p1 2>/dev/null || echo "Route 30.1.4.0/24 already exists"
sudo ip route add 30.1.5.0/24 via 30.2.5.2 dev benic5p1 2>/dev/null || echo "Route 30.1.5.0/24 already exists"
sudo ip route add 30.1.6.0/24 via 30.2.6.2 dev benic6p1 2>/dev/null || echo "Route 30.1.6.0/24 already exists"
sudo ip route add 30.1.7.0/24 via 30.2.7.2 dev benic7p1 2>/dev/null || echo "Route 30.1.7.0/24 already exists"
sudo ip route add 30.1.8.0/24 via 30.2.8.2 dev benic8p1 2>/dev/null || echo "Route 30.1.8.0/24 already exists"

# Verify routes
echo "=== SMC2 Routes to SMC1 ==="
ip route | grep "30.1"

# Test ping to SMC1's first interface
echo "=== Testing connectivity to SMC1 (30.1.1.1) ==="
ping -c 3 30.1.1.1
EOF

    echo "SMC2 configuration complete"
}

case "$SMC_HOST" in
    smc1)
        configure_smc1
        ;;
    smc2)
        configure_smc2
        ;;
    both)
        configure_smc1
        echo ""
        configure_smc2
        ;;
    *)
        echo "Error: Unknown host '$SMC_HOST'"
        echo "Use: smc1, smc2, or both"
        exit 1
        ;;
esac

echo ""
echo "=== Network initialization complete ==="
echo "SMC servers are ready for IB testing"
