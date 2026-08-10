---
name: Fast RDMA state clear between IB runs
description: Use nicctl clear pipeline internal state to reset RDMA anomaly/error state between IB perftest runs instead of card reset + bringup
type: feedback
originSessionId: ed1d2263-4f88-4057-a807-36c650c1b845
---
Between IB perftest runs, clear stale RDMA error/anomaly state with:
`sudo nicctl clear pipeline internal state` (run on each node).

**Why:** The `nicctl show pipeline internal rdma anomalies` detector accumulates stale
error-state QPs from prior (stalled/killed) runs, polluting the next run's pass/fail read.
`nicctl reset card --all` + bringup also clears it but costs ~3 min/node (drops RoCE devices,
needs the bringup script to re-rename/re-apply QoS+paths). The `clear pipeline internal state`
command clears the state in seconds without a card reset or bringup. User flagged the reset+bringup
loop as far too slow (2026-08-10).

**How to apply:** For any IB/RDMA repro loop, clear state (not reset) before each cell; verify with
`nicctl show pipeline internal rdma anomalies` (empty = clean). Only fall back to reset+bringup if a
card is truly wedged and clear-state doesn't recover it.

**IB orchestration gotcha (same session):** don't stream perftest stdout over ssh into a file and
kill with `timeout` — block-buffered output is lost on kill (false "empty log"/"hang"). Run the
server detached on the host (`nohup ... &`), allow >=5s startup before the client, and write logs to
files ON the remote host, then read them back.
