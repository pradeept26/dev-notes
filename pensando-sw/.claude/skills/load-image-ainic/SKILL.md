---
name: load-image
description: Load AINIC firmware onto a Vulcano/Salina testbed (smc, waco, gt, kenya) — official hourly builds from /vol/builds or local dev builds from the workspace. Handles bundle SCP, extraction, nicctl firmware update, card reset, host_sw_pkg install, and bringup. Use when user says load image, load firmware, deploy firmware, update firmware, deploy build, flash nic, deploy to smc.
---

# Load Image Skill

Load AINIC firmware onto a testbed — official builds or local dev builds.

## Usage Examples

- "load 1.125.0-a-233 on smc"
- "load image on smc setup"
- "deploy my local build to smc"
- "update firmware on smc1 and smc2"

## Inputs

| Parameter | Required | Description |
|-----------|----------|-------------|
| testbed | yes | Testbed name (e.g., "smc") — resolved from testbed YAML |
| image | one of these | Official build tag (e.g., "1.125.0-a-233") |
| local_build | one of these | Path to local firmware file (e.g., `ainic_fw_vulcano.tar`) |
| hosts | no | Specific hosts to update (default: all nodes in testbed) |

## Reference Files

The detailed procedures live in these files — **read them before executing**:

| File | Purpose |
|------|---------|
| `~/systest-agentq/projects/ainic/meta-roce/agent-knowledge/testbed-ops/image-loading.md` | **Primary reference** — full image loading procedure with all scenarios, profile handling, cross-pipeline switches, error recovery |
| `~/systest-agentq/projects/ainic/meta-roce/testbeds/<testbed>.yaml` | Testbed config — IPs, credentials, NFS paths, firmware file names |
| `~/systest-agentq/projects/pcie-suite/skills/firmware-operations.md` | Alternative simpler procedure (flash + activate) |
| `~/systest-agentq/projects/ainic/platform/skills/install-firmware.md` | Platform team's install procedure with rollback |

## Procedure

### Step 1: Resolve testbed

Read the testbed YAML from `~/systest-agentq/projects/ainic/meta-roce/testbeds/`.
Extract: host IPs, credentials, asic type, p4_program, NFS bundle path pattern.

### Step 2: Locate firmware

**Official build** (user provides a tag like "1.125.0-a-233"):
- Construct path from testbed YAML `nfs.bundle_path_pattern`
- Check if `/vol/builds/` is mounted locally
- If not, SCP from `nfs.scp_source` (e.g., srv3.pensando.io) using systest credentials
- Stage bundle to `/tmp/` on each target host, extract

**Local dev build** (user provides path or says "my build"):
- Locate `ainic_fw_vulcano.tar` in the workspace build output
- SCP directly to `/tmp/` on each target host
- No bundle extraction needed — just the .tar file

### Step 3: Flash firmware

Read `~/systest-agentq/projects/ainic/meta-roce/agent-knowledge/testbed-ops/image-loading.md`
for the full procedure. Key points:

- Use `nicctl update firmware -i <fw_file>` (NOT `nicctl update firmware -r`)
- Set Bash timeout to **600000ms** (10 min) — 8 NICs takes 5-10 minutes
- Flash all hosts in **parallel**
- Firmware file: `ainic_fw_vulcano.tar` (vulcano) or `ainic_fw_salina.tar` (salina)

### Step 4: Card reset

```bash
ssh $HOST "nicctl reset card --all 2>&1 | tee /tmp/ainic_card_reset.log"
```

Wait for "Card reset successful" for each NIC. If SSH drops (kernel panic),
wait for host to come back via ping loop (up to 5 min).

### Step 5: Install host software (if bundle has host_sw_pkg)

```bash
ssh $HOST "sudo modprobe -r amdgpu"
ssh $HOST "cd <bundle_dir> && tar xzf host_sw_pkg.tar.gz && sudo ./host_sw_pkg/install.sh -y"
ssh $HOST "sudo modprobe amdgpu"
```

Skip this step for local dev builds that only update P4+ firmware.

### Step 6: Verify

```bash
ssh $HOST "nicctl show card --detail | grep 'Firmware version'"
ssh $HOST "ibv_devices | grep -E 'ionic|rocep|roce' | wc -l"  # expect 8
ssh $HOST "lsmod | grep -E 'ionic|pds_core'"
```

### Step 7: Bringup

Run the testbed's bringup script (from testbed YAML `bringup.main_script`) on ALL nodes:
```bash
ssh $HOST "<bringup_script>"
```

### Step 8: Cleanup

```bash
ssh $HOST "rm -rf /tmp/ainic_bundle_*"
```

## Notes

- Do NOT reboot by default — card reset + driver reload is sufficient
- Both FW partitions must have same version for profile changes to work
- After warm reboot, `/tmp/` is cleared — re-SCP bundle if needed
- For profile switches, see the full image-loading.md reference
