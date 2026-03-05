#!/usr/bin/env python3
"""
MSN Context Validation Suite
Comprehensive test and statistics collection for comparing 128-entry vs 256-entry MSN window
"""

import json
import os
import sys
import time
from datetime import datetime
import subprocess

def run_command(cmd, label=""):
    """Run command and return output."""
    print(f"  {label}: {cmd}" if label else f"  {cmd}")
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    return result.stdout

def main():
    test_label = sys.argv[1] if len(sys.argv) > 1 else "128msn-post-change"
    results_dir = os.path.expanduser(f"~/msn-validation/{test_label}")

    print("=" * 70)
    print(f"MSN Context Validation Suite - {test_label}")
    print(f"Results Directory: {results_dir}")
    print("=" * 70)
    print()

    # Create results directory
    os.makedirs(results_dir, exist_ok=True)
    os.chdir(results_dir)

    # Test configuration
    smc1 = "10.30.75.198"
    smc2 = "10.30.75.204"
    user = "ubuntu"
    password = "amd123"

    print("Step 1: Collecting Pre-Test Statistics")
    print("-" * 70)

    # Use Python script's SSH capabilities for stats collection
    stats_cmd = f"""
python3 - <<'PYSCRIPT'
import paramiko
ssh = paramiko.SSHClient()
ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
ssh.connect('{smc1}', username='{user}', password='{password}')
stdin, stdout, stderr = ssh.exec_command('sudo nicctl show stats -j')
print(stdout.read().decode())
ssh.close()
PYSCRIPT
"""

    output = run_command(stats_cmd, "Collecting SMC1 stats")
    with open("smc1_stats_pre.json", "w") as f:
        f.write(output)

    # Similar for SMC2 and other stats...
    print("Pre-test stats collected")
    print()

    print("Step 2: Running Comprehensive IB Tests")
    print("-" * 70)

    # Run the IB benchmark
    ib_cmd = (
        f"~/dev-notes/pensando-sw/scripts/run-ib-test.sh smc1-smc2 "
        f"--max-qp 64 --direction both --write-mode both --xlsx --output-dir {results_dir}"
    )

    print(f"Running: {ib_cmd}")
    result = subprocess.run(ib_cmd, shell=True)

    if result.returncode != 0:
        print(f"Warning: IB test returned code {result.returncode}")

    print()
    print("Step 3: Collecting Post-Test Statistics")
    print("-" * 70)

    # Collect post-test stats (similar to pre-test)
    output = run_command(stats_cmd, "Collecting SMC1 post-test stats")
    with open("smc1_stats_post.json", "w") as f:
        f.write(output)

    print("Post-test stats collected")
    print()

    # Create summary
    with open("test_summary.txt", "w") as f:
        f.write(f"MSN Context Validation - {test_label}\n")
        f.write(f"Date: {datetime.now()}\n")
        f.write(f"\nTest Configuration:\n")
        f.write(f"- QP Counts: 1, 2, 4, 8, 16, 32, 64\n")
        f.write(f"- Directions: Unidirectional, Bidirectional\n")
        f.write(f"- Write Modes: write, write_with_imm\n")
        f.write(f"\nResults Location: {results_dir}\n")

    print("=" * 70)
    print(f"Results saved to: {results_dir}")
    print("=" * 70)

if __name__ == "__main__":
    main()
