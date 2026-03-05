# Salina Hardware Setups

Salina (Pollara) ASIC based hardware configurations for Hydra (and other P4 programs) development and testing.

## Available Setups

### Paired Setups (Primary for RDMA Testing)
- **Dell-Xeon-1-2** - Dell R7625 & R760 paired setup (10.11.x network)
- **Dell-Xeon-3-4** - Dell R760 paired setup (10.30.x network)
- **Dell-Genoa-3-4** - Dell R7625 paired setup (Plan-B images)

### Back-to-Back Setups (AMD Purico Servers)
Each Purico server has 2 Pollara cards connected back-to-back within the same server.

**ByteDance Testbed (Rack J7):**
- **Purico-01-02** - purico01 & purico02 (J7 RU22 & RU20)
- **Purico-03-04** - purico03 & purico04 (J7 RU18 & RU16)
- **Purico-05-06** - purico05 & purico06 (J7 RU14 & RU12)

**Meta RoCE Testbed (Rack J7):**
- **Purico-07-08** - purico07 & purico08 (J7 RU8 & RU10)
- **Purico-09-10** - purico09 & purico10 (J7 RU6 & RU4)

**Other Setups:**
- **Purico-20-21** - Rack L2 RU20-23
- **Purico-22-23** - Rack L2 RU24-27 (Lingua sanity TB)

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
- 10.11.2.23, 10.11.2.25, 10.11.2.26 (Dell setups)
- 10.11.73.104 (Purico J7 rack)
- 10.30.48.254, 10.30.25.254 (Dell Genoa setups)

## Credentials

- **BMC:** \`admin/Pen1nfra$\` or \`root/0penBmc\`
- **Host:** \`root/docker\`
- **A35 Console:** \`admin/N0isystem$\`
- **APC Power:** \`apc/apc\`

## Data Files

All setup configurations are stored as YAML files in the \`data/\` directory:

**Dell Paired Setups:**
- \`dell-xeon-1-2.yml\`
- \`dell-xeon-3-4.yml\`
- \`dell-genoa-3-4.yml\`

**Purico Back-to-Back Setups:**
- \`purico-bytedance-01-02.yml\`
- \`purico-bytedance-03-04.yml\`
- \`purico-meta-07-08.yml\`
- \`purico-meta-09-10.yml\`

---
Last updated: 2026-03-05
