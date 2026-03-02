#!/usr/bin/env python3
"""
Console Manager CLI for Vulcano NICs

Command-line tool for interacting with Vulcano and SuC consoles.

Examples:
    # Show version from all Vulcano consoles on SMC1
    ./console-mgr.py --setup smc1 --console vulcano --all version

    # Reboot all SuC consoles on SMC2
    ./console-mgr.py --setup smc2 --console suc --all reboot

    # Show version from ai0 Vulcano console on SMC1
    ./console-mgr.py --setup smc1 --console vulcano --nic ai0 version

    # Custom command on all consoles
    ./console-mgr.py --setup smc1 --console vulcano --all --cmd "cat /proc/version"
"""

import argparse
import sys
from pathlib import Path
from typing import Optional

# Add parent directory to path to import console_lib
sys.path.insert(0, str(Path(__file__).parent))

from console_lib import ConsoleManager, format_results


# Predefined commands
# Note: Vulcano and SuC consoles have different command syntax
COMMANDS = {
    'version': {
        'vulcano': ['show version'],  # Vulcano-specific command
        'suc': ['version']             # SuC-specific command
    },
    'reboot': {
        'vulcano': None,  # DO NOT reboot Vulcano directly - use SuC instead!
        'suc': ['kernel reboot']  # Reboots the Vulcano kernel from SuC
    },
    'uptime': {
        'vulcano': ['uptime'],
        'suc': ['uptime']
    },
    'status': {
        'vulcano': ['show status', 'show device'],
        'suc': ['status']
    },
    'device': {
        'vulcano': ['show device'],
        'suc': ['show device']
    },
    'dmesg': {
        'vulcano': ['dmesg | tail -30'],
        'suc': ['dmesg | tail -30']
    },
    'ip': {
        'vulcano': ['ip addr show', 'ip route show'],
        'suc': ['ip addr show', 'ip route show']
    },
    'help': {
        'vulcano': ['help'],
        'suc': ['help']
    }
}


def get_commands(command_name: str, console_type: str) -> Optional[list]:
    """
    Get command list for a predefined command.

    Returns:
        List of commands, empty list, or None if not allowed
    """
    if command_name in COMMANDS:
        cmds = COMMANDS[command_name].get(console_type)
        # None means command is not allowed (like reboot on vulcano)
        return cmds
    return []


def main():
    parser = argparse.ArgumentParser(
        description='Console Manager for Vulcano NICs',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__
    )

    # Required arguments
    parser.add_argument('--setup', required=True,
                       help='Setup name (smc1, smc2, gt1, gt4, waco5, waco6)')
    parser.add_argument('--console', required=True, choices=['vulcano', 'suc'],
                       help='Console type: vulcano or suc')

    # Target selection (mutually exclusive)
    target_group = parser.add_mutually_exclusive_group(required=True)
    target_group.add_argument('--all', action='store_true',
                             help='Execute on all NICs')
    target_group.add_argument('--nic',
                             help='Execute on specific NIC (e.g., ai0, ai1)')

    # Command selection
    parser.add_argument('command', nargs='?',
                       choices=list(COMMANDS.keys()),
                       help='Predefined command to execute')
    parser.add_argument('--cmd',
                       help='Custom command to execute')
    parser.add_argument('--no-clear', action='store_true',
                       help='Do not clear console line before execution')
    parser.add_argument('--serial', action='store_true',
                       help='Execute serially instead of parallel (slower)')

    # Configuration
    parser.add_argument('--yaml-dir',
                       default=str(Path(__file__).parent.parent / 'hardware' / 'vulcano' / 'data'),
                       help='Directory containing YAML setup files')

    args = parser.parse_args()

    # Validate command
    if not args.command and not args.cmd:
        parser.error('Either specify a predefined command or use --cmd for custom command')

    if args.command and args.cmd:
        parser.error('Cannot specify both predefined command and --cmd')

    # Initialize console manager
    try:
        mgr = ConsoleManager(args.yaml_dir)
    except Exception as e:
        print(f"ERROR: Failed to initialize console manager: {e}")
        return 1

    # Validate setup exists
    if not mgr.get_setup(args.setup):
        print(f"ERROR: Setup '{args.setup}' not found")
        print(f"Available setups: {', '.join(mgr.list_setups())}")
        return 1

    # Get commands to execute
    if args.command:
        commands = get_commands(args.command, args.console)
        if commands is None:
            print(f"ERROR: Command '{args.command}' is NOT ALLOWED on {args.console} console")
            if args.command == 'reboot' and args.console == 'vulcano':
                print("HINT: To reboot Vulcano, use SuC console instead:")
                print(f"      ./console-mgr.py --setup {args.setup} --console suc --all reboot")
            return 1
        if not commands:
            print(f"ERROR: Command '{args.command}' not available for {args.console} console")
            return 1
    else:
        commands = [args.cmd]

    print(f"Setup: {args.setup}")
    print(f"Console: {args.console}")
    print(f"Target: {'All NICs' if args.all else args.nic}")
    print(f"Commands: {commands}")
    print(f"Clear line: {not args.no_clear}")
    print(f"Parallel: {not args.serial}")
    print()

    # Execute commands
    try:
        if args.all:
            results = mgr.execute_on_all(
                args.setup,
                args.console,
                commands,
                clear_line=not args.no_clear,
                parallel=not args.serial
            )
        else:
            result = mgr.execute_on_console(
                args.setup,
                args.nic,
                args.console,
                commands,
                clear_line=not args.no_clear
            )
            results = [result]

        # Display results
        output = format_results(results)
        print(output)

        # Check for errors
        errors = [r for r in results if 'error' in r]
        if errors:
            print(f"\n\nWARNING: {len(errors)} console(s) had errors")
            return 1

        return 0

    except KeyboardInterrupt:
        print("\n\nInterrupted by user")
        return 130
    except Exception as e:
        print(f"\nERROR: {e}")
        import traceback
        traceback.print_exc()
        return 1


if __name__ == '__main__':
    sys.exit(main())
