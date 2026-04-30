#!/usr/bin/env python3
"""Quick test to see what prompt we get from each console"""

import telnetlib
import time
import sys

def test_console(host, port, expected_type):
    """Test a single console and show raw output."""
    # Clear line first
    PASSWORDS = ['Pen1nfra$', 'N0isystem$']
    line_number = port - 2000

    print(f"\nTesting {host}:{port} (expected: {expected_type}, line {line_number})")
    print("-" * 60)

    # Clear the line
    for pwd in PASSWORDS:
        try:
            tn_mgmt = telnetlib.Telnet(host, 23, timeout=5)
            tn_mgmt.read_until(b"Password:", timeout=3)
            tn_mgmt.write(pwd.encode('ascii') + b"\n")
            time.sleep(0.5)
            tn_mgmt.write(f"clear line {line_number}\n".encode('ascii'))
            time.sleep(0.3)
            tn_mgmt.write(b"\n")
            tn_mgmt.close()
            print(f"  ✓ Line cleared with password: {pwd}")
            time.sleep(1)
            break
        except:
            continue

    # Connect to console
    try:
        tn = telnetlib.Telnet(host, port, timeout=10)
        print(f"  ✓ Connected to console")
        time.sleep(1)

        # Send newline to get prompt
        tn.write(b"\n")
        time.sleep(1)

        # Read output
        output = tn.read_very_eager().decode('ascii', errors='ignore')

        # Show output
        print(f"  Raw output:")
        print(f"  {repr(output)}")
        print(f"\n  Cleaned output:")
        for line in output.split('\n'):
            if line.strip():
                print(f"    {line}")

        # Determine type
        if 'vulcano' in output.lower():
            actual_type = 'VULCANO'
        elif 'suc' in output.lower():
            actual_type = 'SuC'
        else:
            actual_type = 'UNKNOWN'

        if actual_type.lower() == expected_type.lower():
            print(f"\n  ✓ CORRECT: This is a {actual_type} console")
        else:
            print(f"\n  ✗ WRONG: Expected {expected_type}, got {actual_type}")
            print(f"  ACTION NEEDED: Swap this in YAML!")

        tn.close()
        return actual_type

    except Exception as e:
        print(f"  ✗ Error: {e}")
        return None


if __name__ == '__main__':
    # Test first few consoles from SMC1
    print("="*60)
    print("SMC1 Console Verification")
    print("="*60)

    # ai0
    test_console('10.30.69.42', 2003, 'vulcano')
    test_console('10.30.69.42', 2004, 'suc')

    # ai1
    test_console('10.30.69.42', 2005, 'vulcano')
    test_console('10.30.69.42', 2006, 'suc')
