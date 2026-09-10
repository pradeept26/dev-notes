---
name: nicctl internal commands use TAWK; register new opcodes in BOTH tawk.c and zrpc.c
description: Debugging nicctl "err 95 / OP_NOT_SUPPORTED" — nicctl debug/show pipeline internal commands ride the TAWK transport, not fwctl/zrpc; a new IPC opcode must be registered in both tawk.c and zrpc.c or the handler is never reached
type: feedback
originSessionId: 1418ad7a-e393-49d8-aa61-76d2bde9f02b
---
When a new nicmgr IPC opcode returns `err 95` (SDK_RET_OP_NOT_SUPPORTED) from nicctl and the firmware handler is never reached, the cause is almost always a **missing TAWK registration**.

**Why:** nicctl's `debug update pipeline internal *` and `show pipeline internal *` commands ride the **TAWK** transport (`platform/rtos-sw/modules/nicmgr/src/tawk.c` → `ipc_cmd_table`/`internal_ipc_cmd_table`), NOT the fwctl/ZRPC path. A new opcode must be registered in **BOTH**:
- `tawk.c` — add a `*_req_handler(ipc_cmd_t *cmd)` wrapper (mirror AUTO_CLEAR) + `DECLARE_IPC_CMD(...)` in the right table
- `zrpc.c` — `DECLARE_ZRPC_CMD(...)` in `fwctl_ipc_cmd_table` (public) or `fwctl_internal_ipc_cmd_table` (internal)

If registered only in zrpc.c (as the PIC_RL / LLC-meter RL feature was during the a-106→a-119 port), the TAWK dispatch has no entry → returns OP_NOT_SUPPORTED (err 95) and the ipc.c handler (`*_req_handle`) is never invoked. Confirmed by: firmware in-handler trace never firing while `fwctl_rpc_cmd_handler` (fwctl_vdev.c) also never fires — proving the fwctl path is not used at all.

**How to apply:** For any err-95/opcode-not-supported on a private nicmgr feature, FIRST check `grep -c <OPCODE> tawk.c zrpc.c`. Both must be non-zero. Don't rabbit-hole into fwctl/pds_fwctl scope, callback registration (g_rdma_mgr), or opcode-enum skew until the TAWK table is confirmed. The `debug nicmgr trace` verbose/`nicctl show card logs` (persistent) are the tools to confirm which handler is reached.
