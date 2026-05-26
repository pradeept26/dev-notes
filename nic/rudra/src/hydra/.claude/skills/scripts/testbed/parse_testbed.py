#!/usr/bin/env python3
"""
Parse testbed YAML configuration and output JSON for tmux_testbed.sh script.
"""

import sys
import json
import os
import getpass
from pathlib import Path

try:
    import yaml
except ImportError:
    print("Error: PyYAML not installed. Install with: pip install pyyaml", file=sys.stderr)
    sys.exit(1)


def parse_testbed(yaml_file):
    """Parse testbed YAML file and return structured data."""

    # Read YAML file
    try:
        with open(yaml_file, 'r') as f:
            data = yaml.safe_load(f)
    except FileNotFoundError:
        print(f"Error: File '{yaml_file}' not found", file=sys.stderr)
        sys.exit(1)
    except yaml.YAMLError as e:
        print(f"Error: Invalid YAML syntax in '{yaml_file}': {e}", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"Error: Failed to read '{yaml_file}': {e}", file=sys.stderr)
        sys.exit(1)

    # Validate required fields
    if not data:
        print("Error: Empty YAML file", file=sys.stderr)
        sys.exit(1)

    if 'name' not in data:
        print("Error: Missing 'name' field in testbed YAML", file=sys.stderr)
        sys.exit(1)

    if 'nodes' not in data or not data['nodes']:
        print("Error: Missing or empty 'nodes' field in testbed YAML", file=sys.stderr)
        sys.exit(1)

    # Get current username as default
    current_user = getpass.getuser()

    # Process nodes
    processed_nodes = []
    for idx, node in enumerate(data['nodes']):
        if not isinstance(node, dict):
            print(f"Error: Node {idx} is not a dictionary", file=sys.stderr)
            sys.exit(1)

        if 'ip' not in node:
            print(f"Error: Node {idx} missing 'ip' field", file=sys.stderr)
            sys.exit(1)

        # Process setup_commands - can be a list of commands or a single script path
        setup_commands = node.get('setup_commands', [])
        if isinstance(setup_commands, str):
            setup_commands = [setup_commands]

        # Process console - can be a single string or a list
        console = node.get('console', [])
        if isinstance(console, str):
            console = [console] if console else []

        # Process suc - can be a single string or a list
        suc = node.get('suc', [])
        if isinstance(suc, str):
            suc = [suc] if suc else []

        processed_node = {
            'name': node.get('name', f"node{idx}"),
            'ip': node['ip'],
            'username': node.get('username', current_user),
            'password': node.get('password', ''),  # Empty string if not provided
            'console': console,  # List of console connections
            'suc': suc,  # List of SUC console connections
            'setup_commands': setup_commands  # List of commands to run after NIC comes up
        }
        processed_nodes.append(processed_node)

    # Build output structure
    output = {
        'name': data['name'],
        'description': data.get('description', ''),
        'nodes': processed_nodes
    }

    return output


def main():
    if len(sys.argv) != 2:
        print("Usage: parse_testbed.py <testbed_yaml_file>", file=sys.stderr)
        sys.exit(1)

    yaml_file = sys.argv[1]
    testbed_data = parse_testbed(yaml_file)

    # Output JSON to stdout
    print(json.dumps(testbed_data, indent=2))


if __name__ == '__main__':
    main()
