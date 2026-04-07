# Vulcano Setup Data Files

Structured YAML data files for automation and scripting.

## Files

### SMC Setups
- **`smc1.yml`** - SMC1 setup configuration (10.30.75.198)
- **`smc2.yml`** - SMC2 setup configuration (10.30.75.204)

### Waco Cluster (Arista Leaf-Spine)
- **`waco5.yml`** - Waco5 setup configuration (10.30.64.25) - Leaf1
- **`waco6.yml`** - Waco6 setup configuration (10.30.64.26) - Leaf1
- **`waco7.yml`** - Waco7 setup configuration (10.30.64.27) - Leaf2
- **`waco8.yml`** - Waco8 setup configuration (10.30.64.28) - Leaf2

### GT Setups
- **`gt1.yml`** - GT1 setup configuration (10.30.69.101)
- **`gt2.yml`** - GT2 setup configuration
- **`gt4.yml`** - GT4 setup configuration (10.30.69.98)

### Other Setups
- **`waco3.yml`** - Waco3 setup configuration (10.30.64.23)
- **`waco4.yml`** - Waco4 setup configuration (10.30.64.24)
- **`kenya-*.yml`** - Kenya performance test setups

## Structure

Each YAML file contains:

```yaml
setup:           # Setup metadata
  name:          # Setup name
  status:        # active/inactive
  asic:          # vulcano/salina
  use_case:      # Purpose of setup

host:            # Host system info
  hostname:      # Hostname
  mgmt_ip:       # Management IP
  os:            # Operating system
  credentials:   # SSH credentials

bmc:             # BMC/IPMI info
  ip:            # BMC IP
  web_url:       # Web interface URL
  credentials:   # BMC credentials

power:           # Power management
  apc_ip:        # APC IP
  apc_ports:     # Controlled ports
  credentials:   # APC credentials

network:         # Network info
  switch:        # Switch details
  subnet_prefix: # Subnet prefix

nics:            # Array of NICs
  - id:          # ai0-ai7
    interface:   # benic interface name
    mac_address: # MAC address
    serial_number: # FRU serial
    switch:      # Switch connection
      port:      # Switch port
      ip:        # Switch IP
    consoles:    # Console access
      vulcano:   # Vulcano console
        host:    # Console server IP
        port:    # Console port
      suc:       # SuC console
        host:    # Console server IP
        port:    # Console port
```

## Usage Examples

### Python

```python
import yaml

# Load setup data
with open('smc1.yml', 'r') as f:
    smc1 = yaml.safe_load(f)

# Get management IP
mgmt_ip = smc1['host']['mgmt_ip']

# Get console for ai0
ai0_console = smc1['nics'][0]['consoles']['vulcano']
print(f"telnet {ai0_console['host']} {ai0_console['port']}")

# Iterate all NICs
for nic in smc1['nics']:
    print(f"{nic['id']}: {nic['interface']} - {nic['serial_number']}")
```

### Bash with yq

```bash
# Install yq: https://github.com/mikefarah/yq

# Get management IP
yq '.host.mgmt_ip' smc1.yml

# Get all NIC IDs
yq '.nics[].id' smc1.yml

# Get ai0 vulcano console
yq '.nics[] | select(.id == "ai0") | .consoles.vulcano' smc1.yml

# Get all console IPs
yq '.nics[].consoles.vulcano.host' smc1.yml | sort -u
```

### Ansible

```yaml
# playbook.yml
- hosts: localhost
  vars_files:
    - hardware/vulcano/data/smc1.yml

  tasks:
    - name: Connect to all Vulcano consoles
      debug:
        msg: "telnet {{ item.consoles.vulcano.host }} {{ item.consoles.vulcano.port }}"
      loop: "{{ nics }}"
```

### Generate SSH config

```bash
#!/bin/bash
# generate-ssh-config.sh

for setup in smc1 smc2; do
  ip=$(yq '.host.mgmt_ip' data/${setup}.yml)
  user=$(yq '.host.credentials.ssh_user' data/${setup}.yml)

  cat << EOF
Host ${setup}
    HostName ${ip}
    User ${user}
    # Password: $(yq '.host.credentials.ssh_password' data/${setup}.yml)

EOF
done
```

## Validation

You can validate YAML files with schema validators or simple checks:

```bash
# Check YAML syntax
yq '.' smc1.yml > /dev/null && echo "Valid YAML"

# Count NICs
yq '.nics | length' smc1.yml  # Should be 8

# Check all NICs have consoles
yq '.nics[] | select(.consoles.vulcano == null or .consoles.suc == null)' smc1.yml
# Should return empty
```

## Updating Data

When setup details change:

1. Edit the YAML file
2. Optionally regenerate markdown docs from YAML
3. Commit changes to git

## Relationship to Markdown Docs

- **YAML files (this directory):** Source of truth for structured data
- **Markdown files (parent directory):** Human-readable documentation with procedures, troubleshooting, etc.

Both are maintained and kept in sync.
