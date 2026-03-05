# Salina Hardware Setups

Salina (Pollara) ASIC based hardware configurations for Hydra (and other P4 programs) development and testing.

## Available Setups

### Paired Setups (Primary for RDMA Testing)
- **Dell-Xeon-1-2** - Dell R7625 & R760 paired setup (10.11.x network)
- **Dell-Xeon-3-4** - Dell R760 paired setup (10.30.x network)
- **Dell-Genoa-3-4** - Dell R7625 paired setup (Plan-B images)

### Back-to-Back Setups (Single Server)
- Multiple Purico servers with 2 Pollara cards each
- Useful for local testing without network dependencies

## Salina/Pollara Overview

**ASIC:** Salina (also known as Pollara in test bench naming)  
**Primary P4 Programs:** Hydra, Pulsar, Lynx  
**Product Family:** AINIC (AI NIC) / DPU  
**Architecture:** A35 ARM processor + Salina ASIC

## Common Salina Commands

### Firmware Management
\`\`\`bash
# Flash firmware (same as Vulcano)
nicctl update firmware -i /path/to/ainic_fw_salina.tar

# Check firmware version
nicctl show version

# View device info
nicctl show card
nicctl show device
\`\`\`

### Debug Tools
\`\`\`bash
# ASIC monitor (Salina-specific)
salinamon

# Standard nicctl commands work identically to Vulcano
nicctl show card -j
nicctl show version -j
\`\`\`

### RDMA Operations
\`\`\`bash
# List RDMA devices
ibv_devinfo

# Show device attributes
ibv_devinfo -v

# Run perftest
ib_write_bw -d <device>
ib_read_bw -d <device>
\`\`\`

## Firmware Images

**Location on build machine:** \`/sw/naples_salina_a35_ainic.tar\` or \`/sw/ainic_fw_salina.tar\`

**Image types:**
- A35 FW (most common): \`naples_salina_a35_ainic.tar\`
- Full AINIC bundle: \`ainic_fw_salina.tar\`
- Base/Plan-B FW: \`naples_salina_a35_ainic_base.tar\`

## Build Commands (Salina Hydra)

### Quick A35 Build (Most Common)
\`\`\`bash
# Inside Docker at /sw
make PIPELINE=rudra P4_PROGRAM=hydra rudra-salina-ainic-a35-fw
# Output: /sw/naples_salina_a35_ainic.tar
\`\`\`

### Full Bundle Build
\`\`\`bash
# Inside Docker at /sw
make -f Makefile.build build-rudra-salina-hydra-ainic-bundle
# Output: /sw/ainic_fw_salina.tar
\`\`\`

## Key Differences from Vulcano

| Aspect | Vulcano | Salina |
|--------|---------|--------|
| **ASIC Name** | Vulcano | Salina (Pollara in TB) |
| **Monitor Tool** | vulcanomon | salinamon |
| **Console** | Vulcano console | A35 console |
| **Firmware** | ainic_fw_vulcano.tar | ainic_fw_salina.tar |

**Important:** \`nicctl\` commands work **identically** on both ASICs.

## Console Access Pattern

Format: \`telnet <console_server_ip> <port>\`

**Console Servers:**
- 10.11.2.23, 10.11.2.25, 10.11.2.26
- 10.30.48.254, 10.30.25.254

## Credentials

- **BMC:** \`admin/Pen1nfra$\` or \`root/0penBmc\`
- **Host:** \`root/docker\`
- **A35 Console:** \`admin/N0isystem$\`
- **APC Power:** \`apc/apc\`

## Data Files

All setup configurations are stored as YAML files in the \`data/\` directory:
- \`dell-xeon-1-2.yml\`
- \`dell-xeon-3-4.yml\`
- \`dell-genoa-3-4.yml\`

---
Last updated: 2026-03-05
