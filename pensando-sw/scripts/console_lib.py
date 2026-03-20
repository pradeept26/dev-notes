#!/usr/bin/env python3
"""
Console Manager Library for Vulcano NICs

Provides classes and utilities for managing telnet console connections
to Vulcano and SuC consoles across multiple hardware setups.

Author: Auto-generated
"""

import telnetlib
import time
import re
import yaml
from pathlib import Path
from typing import Dict, List, Optional, Tuple
from concurrent.futures import ThreadPoolExecutor, as_completed


class ConsoleSession:
    """Manages a single telnet console session."""

    # Console server passwords to try
    CONSOLE_PASSWORDS = ['Pen1nfra$', 'N0isystem$']

    def __init__(self, host: str, port: int, timeout: int = 10, auto_clear: bool = True):
        """
        Initialize console session.

        Args:
            host: Console server IP
            port: Console server port
            timeout: Connection timeout in seconds
            auto_clear: Automatically clear busy lines
        """
        self.host = host
        self.port = port
        self.timeout = timeout
        self.auto_clear = auto_clear
        self.tn = None
        self.connected = False

    def clear_console_line(self, line_number: int) -> bool:
        """
        Clear a console line by connecting to the console server.

        Args:
            line_number: Line number to clear (derived from port)

        Returns:
            True if successful, False otherwise
        """
        print(f"  Attempting to clear line {line_number} on {self.host}...")

        for password in self.CONSOLE_PASSWORDS:
            try:
                # Connect to console server (port 23 - standard telnet)
                tn_mgmt = telnetlib.Telnet(self.host, 23, timeout=self.timeout)

                # Wait for password prompt
                tn_mgmt.read_until(b"Password:", timeout=5)

                # Send password
                tn_mgmt.write(password.encode('ascii') + b"\n")

                # Wait for prompt after password - use read_until to wait for '#'
                try:
                    prompt_response = tn_mgmt.read_until(b"#", timeout=5).decode('ascii', errors='ignore')

                    # Check for password failure
                    if any(word in prompt_response.lower() for word in ['incorrect', 'failed', 'bad password', '% bad']):
                        print(f"  Password {password} failed")
                        continue

                    # Success - we got the '#' prompt
                    print(f"  Authenticated successfully with {password}")

                except Exception:
                    # Timeout waiting for prompt - password probably failed
                    print(f"  No prompt with {password}, trying next...")
                    continue

                # Send clear line command
                clear_cmd = f"clear line {line_number}\n"
                tn_mgmt.write(clear_cmd.encode('ascii'))
                time.sleep(1.5)

                # Read the response to see if there's a confirmation prompt
                response = tn_mgmt.read_very_eager().decode('ascii', errors='ignore')

                # Debug: print what we got
                print(f"  Console server response: {response[:100]}")

                # Send confirmation (both 'y' and Enter to cover all cases)
                if 'confirm' in response.lower() or '[y/n]' in response.lower() or '[' in response:
                    print(f"  Sending 'y' for confirmation")
                    tn_mgmt.write(b"y\n")
                else:
                    print(f"  Sending Enter")
                    tn_mgmt.write(b"\n")
                time.sleep(1.5)

                # Read final response to confirm clearing
                final_response = tn_mgmt.read_very_eager().decode('ascii', errors='ignore')
                print(f"  Final response: {final_response[:100]}")

                # Close management connection
                tn_mgmt.close()

                print(f"  Line {line_number} cleared successfully")
                time.sleep(3)  # Wait 3 seconds for line to fully release
                return True

            except Exception as e:
                print(f"  Failed with password {password}: {e}")
                continue

        print(f"  Failed to clear line {line_number}")
        return False

    def connect(self, retry_with_clear: bool = True, retry_count: int = 0) -> bool:
        """
        Establish telnet connection to console.

        Args:
            retry_with_clear: Retry after clearing line if connection refused
            retry_count: Number of retries attempted so far

        Returns:
            True if successful, False otherwise
        """
        max_retries = 3

        try:
            self.tn = telnetlib.Telnet(self.host, self.port, timeout=self.timeout)
            self.connected = True
            time.sleep(0.5)  # Give console time to respond
            return True
        except ConnectionRefusedError as e:
            if self.auto_clear and retry_with_clear and retry_count < max_retries:
                # Connection refused - line is busy, try to clear it
                # Line number is typically port - 2000
                # e.g., port 2002 = line 2, port 2003 = line 3
                line_number = self.port - 2000

                print(f"Connection refused to {self.host}:{self.port} (line busy)")
                if self.clear_console_line(line_number):
                    # Wait progressively longer between retries
                    wait_time = 2 + retry_count
                    print(f"Waiting {wait_time} seconds before retry...")
                    time.sleep(wait_time)

                    print(f"\nRetry {retry_count + 1}/{max_retries}...")
                    # Retry connection after clearing
                    return self.connect(retry_with_clear=True, retry_count=retry_count + 1)

            print(f"Connection failed to {self.host}:{self.port}: {e}")
            return False
        except Exception as e:
            print(f"Connection failed to {self.host}:{self.port}: {e}")
            return False

    def disconnect(self):
        """Close the telnet connection."""
        if self.tn:
            try:
                self.tn.close()
            except:
                pass
            self.connected = False

    def clear_line(self):
        """Clear the console line (send ~#)."""
        if not self.connected:
            return False
        try:
            self.tn.write(b"~#")
            time.sleep(0.5)
            # Read any response
            self.tn.read_very_eager()
            return True
        except Exception as e:
            print(f"Failed to clear line: {e}")
            return False

    def send_command(self, command: str, wait: float = 1.0,
                     expect: Optional[str] = None) -> str:
        """
        Send command and get output.

        Args:
            command: Command to send
            wait: Time to wait for output (seconds)
            expect: Optional string to wait for in output

        Returns:
            Command output as string
        """
        if not self.connected:
            return ""

        try:
            # Send command
            self.tn.write(command.encode('ascii') + b"\n")

            if expect:
                # Wait for expected string
                output = self.tn.read_until(expect.encode('ascii'), timeout=wait)
            else:
                # Wait fixed time
                time.sleep(wait)
                output = self.tn.read_very_eager()

            return output.decode('ascii', errors='ignore')
        except Exception as e:
            return f"Error executing command: {e}"

    def send_break(self):
        """Send break signal (Ctrl+C)."""
        if self.connected:
            self.tn.write(b"\x03")
            time.sleep(0.2)

    def __enter__(self):
        """Context manager entry."""
        self.connect()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        """Context manager exit."""
        self.disconnect()


class ConsoleManager:
    """Manages console connections for hardware setups."""

    def __init__(self, yaml_dir: str):
        """
        Initialize console manager.

        Args:
            yaml_dir: Directory containing YAML setup files
        """
        self.yaml_dir = Path(yaml_dir)
        self.setups = {}
        self._load_setups()

    def _load_setups(self):
        """Load all YAML setup files."""
        if not self.yaml_dir.exists():
            raise FileNotFoundError(f"YAML directory not found: {self.yaml_dir}")

        for yaml_file in self.yaml_dir.glob("*.yml"):
            if yaml_file.name == "README.md":
                continue

            with open(yaml_file) as f:
                setup_data = yaml.safe_load(f)
                setup_name = setup_data['setup']['name']
                self.setups[setup_name.lower()] = setup_data

    def get_setup(self, setup_name: str) -> Optional[Dict]:
        """
        Get setup configuration.

        Args:
            setup_name: Name of setup (e.g., 'smc1', 'gt1')

        Returns:
            Setup configuration dict or None
        """
        return self.setups.get(setup_name.lower())

    def list_setups(self) -> List[str]:
        """Get list of available setup names."""
        return list(self.setups.keys())

    def get_console_info(self, setup_name: str, nic_id: str,
                         console_type: str) -> Optional[Tuple[str, int]]:
        """
        Get console host and port for a specific NIC.

        Args:
            setup_name: Name of setup
            nic_id: NIC ID (e.g., 'ai0', 'ai1')
            console_type: 'vulcano', 'suc', or 'a35'

        Returns:
            Tuple of (host, port) or None
        """
        setup = self.get_setup(setup_name)
        if not setup:
            return None

        # Handle both old and new formats
        # Old format (Vulcano): nics[].consoles.vulcano/suc
        # New format (Salina): nics[].a35_console, nics[].suc_console
        # Also support server1/server2 structure for paired setups

        # Check if this is a paired setup (has server1/server2)
        for server_key in ['server1', 'server2']:
            server = setup.get(server_key)
            if server:
                for nic in server.get('nics', []):
                    if nic['id'] == nic_id:
                        # Try new format first (a35_console, suc_console)
                        console_key = f"{console_type}_console"
                        console = nic.get(console_key)
                        if console:
                            return (console['host'], console['port'])
                        # Try old format (consoles.a35, consoles.suc)
                        console = nic.get('consoles', {}).get(console_type)
                        if console:
                            return (console['host'], console['port'])

        # Check regular nics array
        for nic in setup.get('nics', []):
            if nic['id'] == nic_id:
                # Try new format first (a35_console, suc_console)
                console_key = f"{console_type}_console"
                console = nic.get(console_key)
                if console:
                    return (console['host'], console['port'])
                # Try old format (consoles.vulcano, consoles.suc)
                console = nic.get('consoles', {}).get(console_type)
                if console:
                    return (console['host'], console['port'])

        return None

    def get_all_consoles(self, setup_name: str,
                         console_type: str) -> List[Tuple[str, str, int]]:
        """
        Get all console connections for a setup.

        Args:
            setup_name: Name of setup
            console_type: 'vulcano', 'suc', or 'a35'

        Returns:
            List of tuples (nic_id, host, port)
        """
        setup = self.get_setup(setup_name)
        if not setup:
            return []

        consoles = []

        # Handle paired setups (server1/server2)
        for server_key in ['server1', 'server2']:
            server = setup.get(server_key)
            if server:
                for nic in server.get('nics', []):
                    nic_id = nic['id']
                    # Try new format (a35_console, suc_console)
                    console_key = f"{console_type}_console"
                    console = nic.get(console_key)
                    if console:
                        consoles.append((nic_id, console['host'], console['port']))
                    else:
                        # Try old format (consoles.vulcano, consoles.suc)
                        console = nic.get('consoles', {}).get(console_type)
                        if console:
                            consoles.append((nic_id, console['host'], console['port']))

        # Handle regular nics array
        for nic in setup.get('nics', []):
            nic_id = nic['id']
            # Try new format
            console_key = f"{console_type}_console"
            console = nic.get(console_key)
            if console:
                consoles.append((nic_id, console['host'], console['port']))
            else:
                # Try old format
                console = nic.get('consoles', {}).get(console_type)
                if console:
                    consoles.append((nic_id, console['host'], console['port']))

        return consoles

    def execute_on_console(self, setup_name: str, nic_id: str,
                          console_type: str, commands: List[str],
                          clear_line: bool = True) -> Dict[str, str]:
        """
        Execute commands on a single console.

        Args:
            setup_name: Name of setup
            nic_id: NIC ID
            console_type: 'vulcano' or 'suc'
            commands: List of commands to execute
            clear_line: Whether to clear line at server before connecting

        Returns:
            Dict with command outputs
        """
        console_info = self.get_console_info(setup_name, nic_id, console_type)
        if not console_info:
            return {'error': f'Console not found for {setup_name}/{nic_id}/{console_type}'}

        host, port = console_info
        result = {
            'nic_id': nic_id,
            'console_type': console_type,
            'host': host,
            'port': port,
            'outputs': []
        }

        try:
            # auto_clear=True means it will clear line at server if connection refused
            with ConsoleSession(host, port, auto_clear=clear_line) as session:
                if not session.connected:
                    result['error'] = 'Failed to connect'
                    return result

                # Send newline to get prompt
                session.send_command("", wait=0.5)

                # Execute commands
                for cmd in commands:
                    output = session.send_command(cmd, wait=2.0)
                    result['outputs'].append({
                        'command': cmd,
                        'output': output
                    })
        except Exception as e:
            result['error'] = str(e)

        return result

    def execute_on_all(self, setup_name: str, console_type: str,
                       commands: List[str], clear_line: bool = True,
                       parallel: bool = True) -> List[Dict]:
        """
        Execute commands on all consoles of a setup.

        Args:
            setup_name: Name of setup
            console_type: 'vulcano' or 'suc'
            commands: List of commands to execute
            clear_line: Whether to clear line before executing
            parallel: Execute in parallel (faster) or serial

        Returns:
            List of result dicts from each console
        """
        consoles = self.get_all_consoles(setup_name, console_type)
        if not consoles:
            return [{'error': f'No consoles found for {setup_name}/{console_type}'}]

        if parallel:
            results = []
            with ThreadPoolExecutor(max_workers=8) as executor:
                futures = {}
                for nic_id, host, port in consoles:
                    future = executor.submit(
                        self.execute_on_console,
                        setup_name, nic_id, console_type, commands, clear_line
                    )
                    futures[future] = nic_id

                for future in as_completed(futures):
                    results.append(future.result())

            # Sort by nic_id
            results.sort(key=lambda x: x.get('nic_id', ''))
            return results
        else:
            results = []
            for nic_id, host, port in consoles:
                result = self.execute_on_console(
                    setup_name, nic_id, console_type, commands, clear_line
                )
                results.append(result)
            return results


def format_results(results: List[Dict], command: str = None) -> str:
    """
    Format command results for display.

    Args:
        results: List of result dicts
        command: Optional command to highlight in output

    Returns:
        Formatted string
    """
    output_lines = []

    for result in results:
        if 'error' in result and 'nic_id' not in result:
            output_lines.append(f"ERROR: {result['error']}")
            continue

        nic_id = result.get('nic_id', 'unknown')
        console_type = result.get('console_type', 'unknown')
        host = result.get('host', 'unknown')
        port = result.get('port', 'unknown')

        header = f"\n{'='*70}\n"
        header += f"NIC: {nic_id} | Console: {console_type} | {host}:{port}\n"
        header += f"{'='*70}"
        output_lines.append(header)

        if 'error' in result:
            output_lines.append(f"ERROR: {result['error']}")
        else:
            for cmd_result in result.get('outputs', []):
                cmd = cmd_result['command']
                output = cmd_result['output']
                output_lines.append(f"\n> {cmd}")
                output_lines.append(output)

    return '\n'.join(output_lines)
