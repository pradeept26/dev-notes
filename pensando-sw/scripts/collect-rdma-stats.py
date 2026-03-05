#!/usr/bin/env python3
"""Collect RDMA/Hydra statistics from SMC hosts for MSN validation"""

import json
import sys
import paramiko
from datetime import datetime

def collect_stats(host_ip, username, password, label):
    """Collect all relevant RDMA statistics from a host."""
    print(f"\nCollecting stats from {label} ({host_ip})...")

    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh.connect(host_ip, username=username, password=password)

    stats = {
        "host": host_ip,
        "label": label,
        "timestamp": datetime.now().isoformat(),
    }

    # Collect nicctl stats
    stdin, stdout, stderr = ssh.exec_command("sudo nicctl show stats -j")
    stats["nicctl_stats"] = stdout.read().decode()

    # Collect RDMA LIF stats
    stdin, stdout, stderr = ssh.exec_command("sudo nicctl show lif rdma -j")
    stats["rdma_lif"] = stdout.read().decode()

    # Collect pipeline RDMA stats
    stdin, stdout, stderr = ssh.exec_command("sudo nicctl show pipeline rdma -j 2>/dev/null || echo '{}'")
    stats["pipeline_rdma"] = stdout.read().decode()

    ssh.close()
    return stats

def main():
    label = sys.argv[1] if len(sys.argv) > 1 else "post-change"
    output_file = f"rdma_stats_{label}.json"

    # SMC hosts
    hosts = [
        ("10.30.75.198", "ubuntu", "amd123", "SMC1"),
        ("10.30.75.204", "ubuntu", "amd123", "SMC2"),
    ]

    all_stats = []
    for host_ip, username, password, host_label in hosts:
        try:
            stats = collect_stats(host_ip, username, password, host_label)
            all_stats.append(stats)
        except Exception as e:
            print(f"Error collecting from {host_label}: {e}")

    # Save to file
    with open(output_file, "w") as f:
        json.dump(all_stats, f, indent=2)

    print(f"\nStats saved to: {output_file}")

    # Print key counters
    print("\n" + "="*70)
    print("KEY STATISTICS SUMMARY")
    print("="*70)

    for stats in all_stats:
        print(f"\n{stats['label']} ({stats['host']}):")
        try:
            nicctl_json = json.loads(stats["nicctl_stats"])
            # Extract RNR and drop counters
            # Structure varies, so we'll print what we find
            print(f"  Stats collected: {len(str(nicctl_json))} bytes")
        except:
            pass

if __name__ == "__main__":
    main()
