---
name: decode-exception
description: Decode MPU exceptions from logs
triggers:
  - decode exception
  - mpu exception
  - decode crash
  - firmware crash
  - parse exception
---

# Decode MPU Exception Skill

Decode MPU (Micro Processing Unit) exceptions from firmware logs or UART output.

## Usage Examples

- "decode this MPU exception"
- "what caused this firmware crash"
- "parse exception from uart log"

## Scripts

Use the canonical decoder in the source tree — do not maintain copies in `.claude/`.

```bash
# From a captured eth_dbgtool dump
eth_dbgtool memrd <base_addr> 6144 | nic/rudra/tools/decode_mpu_exception.py --base <base_addr>

# Direct PAL read on a NIC host (auto-discovers base addr from mem.json)
nic/rudra/tools/decode_mpu_exception.py --pal
```

For a remote NIC reachable only via console/telnet, set the PAL telnet env vars
and use the same canonical script — `pal_telnet.cc` will tunnel `pal.mem_rd`
through the console:

```bash
PAL_TELNET_IPADDR=<console_host> PAL_TELNET_PORT=<console_port> \
  nic/rudra/tools/decode_mpu_exception.py --pal --base <base_addr>
```

## Steps

1. Identify log source (techsupport, eth_dbgtool dump, live host, remote-via-telnet)
2. Extract exception information
3. Run the canonical decoder with the matching transport
4. Explain exception cause and location

## Exception Format

MPU exceptions typically contain:
- Exception type (illegal instruction, memory fault, etc.)
- Program counter (PC)
- Stage and table info
- Register dump

## Common Exception Types

| Type | Description |
|------|-------------|
| Illegal Instruction | Invalid opcode executed |
| Memory Access Fault | Bad address access |
| Table Lookup Error | P4 table miss/error |
| DMA Error | DMA transfer failed |

## Output

The decoder provides:
- Exception type and description
- Faulting stage and program
- Source file and line (if debug info available)
- Register state at fault

## Notes

- Debug builds provide better symbol information
- UART logs may have incomplete data
- Collect techsupport for full context
