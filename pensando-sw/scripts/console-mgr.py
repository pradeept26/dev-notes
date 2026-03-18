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
import os
import time
from pathlib import Path
from typing import Optional

# Add parent directory to path to import console_lib
sys.path.insert(0, str(Path(__file__).parent))

from console_lib import ConsoleManager, format_results


def interactive_console(setup_name: str, nic_id: str, console_type: str, clear_line: bool = True) -> int:
    """
    Open an interactive telnet console session.

    Args:
        setup_name: Setup name (e.g., 'waco2')
        nic_id: NIC ID (e.g., 'ai0')
        console_type: Console type ('vulcano', 'suc', or 'a35')
        clear_line: Whether to clear the console line before connecting

    Returns:
        Exit code
    """
    # Initialize console manager
    try:
        mgr = None
        for dir_path in [Path(__file__).parent.parent / 'hardware' / 'vulcano' / 'data',
                         Path(__file__).parent.parent / 'hardware' / 'salina' / 'data']:
            if dir_path.exists():
                try:
                    temp_mgr = ConsoleManager(str(dir_path))
                    if temp_mgr.get_setup(setup_name):
                        mgr = temp_mgr
                        break
                except:
                    pass

        if not mgr:
            mgr = ConsoleManager(str(Path(__file__).parent.parent / 'hardware' / 'vulcano' / 'data'))
    except Exception as e:
        print(f"ERROR: Failed to initialize console manager: {e}")
        return 1

    # Get console info
    console_info = mgr.get_console_info(setup_name, nic_id, console_type)
    if not console_info:
        print(f"ERROR: Console not found for {setup_name}/{nic_id}/{console_type}")
        print(f"Available setups: {', '.join(mgr.list_setups())}")
        return 1

    host, port = console_info

    print(f"========================================")
    print(f"Interactive Console Session")
    print(f"========================================")
    print(f"Setup:   {setup_name}")
    print(f"NIC:     {nic_id}")
    print(f"Console: {console_type}")
    print(f"Server:  {host}:{port}")
    print(f"========================================")
    print()

    # Try to clear line if requested
    if clear_line:
        from console_lib import ConsoleSession

        # Try to clear and connect with retries
        max_retries = 3
        for attempt in range(max_retries):
            if attempt > 0:
                print(f"\nRetry {attempt}/{max_retries-1}...")

            session = ConsoleSession(host, port, auto_clear=True)
            if session.connect():
                session.disconnect()
                print("Console line cleared and ready")
                print()
                # Wait longer after successful clear
                print("Waiting 3 seconds for line to fully release...")
                time.sleep(3)
                break
            else:
                if attempt < max_retries - 1:
                    print(f"Waiting 2 seconds before retry...")
                    time.sleep(2)
        else:
            print("\nWarning: Could not clear console line after retries")
            print("The line may be stuck - trying direct connection anyway...")
            print()

    print(f"Connecting to telnet {host} {port}...")
    print()
    print(f"IMPORTANT: Once connected, press ENTER to get the console prompt!")
    print()
    print(f"To exit: Ctrl+] then type 'quit'")
    print()
    time.sleep(1)

    # Execute telnet directly - pass control to user
    os.execvp('telnet', ['telnet', host, str(port)])

    return 0


# Predefined commands
# Note: Vulcano, SuC, and a35 (Salina) consoles have different command syntax
COMMANDS = {
    'version': {
        'vulcano': ['show version'],  # Vulcano-specific command
        'suc': ['version'],            # SuC-specific command
        'a35': ['show version']        # Salina a35 console (similar to Vulcano)
    },
    'reboot': {
        'vulcano': None,  # DO NOT reboot Vulcano directly - use SuC instead!
        'suc': ['kernel reboot'],  # Reboots the Vulcano kernel from SuC
        'a35': ['reboot']  # Salina reboot (no SuC on Salina)
    },
    'uptime': {
        'vulcano': ['uptime'],
        'suc': ['uptime'],
        'a35': ['uptime']
    },
    'status': {
        'vulcano': ['show status', 'show device'],
        'suc': ['status'],
        'a35': ['show status', 'show device']
    },
    'device': {
        'vulcano': ['show device'],
        'suc': ['show device'],
        'a35': ['show device']
    },
    'dmesg': {
        'vulcano': ['dmesg | tail -30'],
        'suc': ['dmesg | tail -30'],
        'a35': ['dmesg | tail -30']
    },
    'ip': {
        'vulcano': ['ip addr show', 'ip route show'],
        'suc': ['ip addr show', 'ip route show'],
        'a35': ['ip addr show', 'ip route show']
    },
    'help': {
        'vulcano': ['help'],
        'suc': ['help'],
        'a35': ['help']
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
    parser.add_argument('--console', required=True, choices=['vulcano', 'suc', 'a35'],
                       help='Console type: vulcano, suc, or a35 (for Salina)')

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
    parser.add_argument('--interactive', action='store_true',
                       help='Interactive console session (opens telnet directly)')
    parser.add_argument('--no-clear', action='store_true',
                       help='Do not clear console line before execution')
    parser.add_argument('--serial', action='store_true',
                       help='Execute serially instead of parallel (slower)')

    # Configuration
    parser.add_argument('--yaml-dir',
                       help='Directory containing YAML setup files (auto-detected if not specified)')

    args = parser.parse_args()

    # Handle interactive mode
    if args.interactive:
        if args.all:
            parser.error('Interactive mode requires --nic (cannot use --all)')
        if args.command or args.cmd:
            parser.error('Interactive mode does not use commands')

        # Interactive mode - open telnet connection directly
        return interactive_console(args.setup, args.nic, args.console, not args.no_clear)

    # Validate command
    if not args.command and not args.cmd:
        parser.error('Either specify a predefined command or use --cmd for custom command')

    if args.command and args.cmd:
        parser.error('Cannot specify both predefined command and --cmd')

    # Auto-detect YAML directory if not specified
    if not args.yaml_dir:
        # Try Vulcano first, then Salina
        base_path = Path(__file__).parent.parent / 'hardware'
        vulcano_dir = base_path / 'vulcano' / 'data'
        salina_dir = base_path / 'salina' / 'data'

        # Try both directories and merge
        yaml_dir = None
        if vulcano_dir.exists():
            yaml_dir = str(vulcano_dir)
        if salina_dir.exists():
            yaml_dir = str(salina_dir) if not yaml_dir else yaml_dir
    else:
        yaml_dir = args.yaml_dir

    # Initialize console manager
    try:
        # Try to load from both Vulcano and Salina directories
        mgr = None
        for dir_path in [Path(__file__).parent.parent / 'hardware' / 'vulcano' / 'data',
                         Path(__file__).parent.parent / 'hardware' / 'salina' / 'data']:
            if dir_path.exists():
                try:
                    temp_mgr = ConsoleManager(str(dir_path))
                    if temp_mgr.get_setup(args.setup):
                        mgr = temp_mgr
                        break
                except:
                    pass

        if not mgr:
            # Fall back to specified or default directory
            mgr = ConsoleManager(yaml_dir if yaml_dir else str(Path(__file__).parent.parent / 'hardware' / 'vulcano' / 'data'))
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
