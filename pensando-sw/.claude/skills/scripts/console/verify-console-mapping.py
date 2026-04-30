#!/usr/bin/env python3
"""
Verify Console Mapping - Check if Vulcano/SuC consoles are correctly mapped

This script connects to each console and checks the prompt to verify
if the console type (vulcano vs suc) is correctly identified.
"""

import sys
import telnetlib
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from console_lib import ConsoleManager


def check_console_prompt(host, port, timeout=10):
    """
    Connect to console and check what prompt we get.

    Returns:
        Tuple of (success, prompt_type, prompt_text)
        prompt_type: 'vulcano', 'suc', 'unknown'
    """
    # Try to clear line first
    CONSOLE_PASSWORDS = ['Pen1nfra$', 'N0isystem$']
    line_number = port - 2000

    # Try to clear line
    for password in CONSOLE_PASSWORDS:
        try:
            tn_mgmt = telnetlib.Telnet(host, 23, timeout=5)
            tn_mgmt.read_until(b"Password:", timeout=3)
            tn_mgmt.write(password.encode('ascii') + b"\n")
            time.sleep(0.5)
            tn_mgmt.write(f"clear line {line_number}\n".encode('ascii'))
            time.sleep(0.3)
            tn_mgmt.write(b"\n")
            time.sleep(0.3)
            tn_mgmt.close()
            time.sleep(1)
            break
        except:
            pass

    # Connect to console
    try:
        tn = telnetlib.Telnet(host, port, timeout=timeout)
        time.sleep(0.5)

        # Send newline to get prompt
        tn.write(b"\n")
        time.sleep(1)

        # Read output
        output = tn.read_very_eager().decode('ascii', errors='ignore')

        # Close connection
        tn.close()

        # Analyze prompt
        if 'vulcano:' in output.lower() or 'vulcano~' in output.lower():
            return (True, 'vulcano', output.strip())
        elif 'suc' in output.lower():
            return (True, 'suc', output.strip())
        else:
            return (True, 'unknown', output.strip())

    except Exception as e:
        return (False, 'error', str(e))


def verify_setup(mgr, setup_name):
    """Verify console mapping for a setup."""
    setup = mgr.get_setup(setup_name)
    if not setup:
        print(f"Setup {setup_name} not found")
        return

    print(f"\n{'='*80}")
    print(f"Verifying Console Mapping for: {setup_name.upper()}")
    print(f"{'='*80}\n")

    issues = []

    for nic in setup.get('nics', []):
        nic_id = nic['id']
        print(f"\nChecking {nic_id}...")

        # Check Vulcano console
        vulcano_console = nic.get('consoles', {}).get('vulcano', {})
        if vulcano_console:
            host = vulcano_console['host']
            port = vulcano_console['port']
            print(f"  Vulcano console: {host}:{port}")

            success, prompt_type, output = check_console_prompt(host, port)
            if success:
                if prompt_type == 'vulcano':
                    print(f"    ✓ Correctly mapped - got vulcano prompt")
                elif prompt_type == 'suc':
                    print(f"    ✗ WRONG! Got SuC prompt, but labeled as Vulcano")
                    issues.append(f"{nic_id}: Vulcano console {host}:{port} is actually SuC")
                else:
                    print(f"    ? Unknown prompt type: {output[:50]}...")
            else:
                print(f"    ! Error: {output}")

        # Check SuC console
        suc_console = nic.get('consoles', {}).get('suc', {})
        if suc_console:
            host = suc_console['host']
            port = suc_console['port']
            print(f"  SuC console: {host}:{port}")

            success, prompt_type, output = check_console_prompt(host, port)
            if success:
                if prompt_type == 'suc':
                    print(f"    ✓ Correctly mapped - got suc prompt")
                elif prompt_type == 'vulcano':
                    print(f"    ✗ WRONG! Got Vulcano prompt, but labeled as SuC")
                    issues.append(f"{nic_id}: SuC console {host}:{port} is actually Vulcano")
                else:
                    print(f"    ? Unknown prompt type: {output[:50]}...")
            else:
                print(f"    ! Error: {output}")

    # Summary
    print(f"\n{'='*80}")
    if issues:
        print(f"ISSUES FOUND ({len(issues)}):")
        for issue in issues:
            print(f"  - {issue}")
        print("\nYou need to swap Vulcano/SuC mappings in the YAML file!")
    else:
        print(f"✓ All console mappings are CORRECT for {setup_name}")
    print(f"{'='*80}\n")

    return issues


if __name__ == '__main__':
    import argparse

    parser = argparse.ArgumentParser(description='Verify console mapping')
    parser.add_argument('--setup', required=True, help='Setup name to verify')
    parser.add_argument('--yaml-dir',
                       default=str(Path(__file__).parent.parent / 'hardware' / 'vulcano' / 'data'),
                       help='YAML directory')

    args = parser.parse_args()

    try:
        mgr = ConsoleManager(args.yaml_dir)
        issues = verify_setup(mgr, args.setup)

        sys.exit(1 if issues else 0)

    except Exception as e:
        print(f"ERROR: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)
