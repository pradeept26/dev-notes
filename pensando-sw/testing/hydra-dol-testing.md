# Hydra DOL Testing - Vulcano ASIC

DOL (Descore Operating Layer) integration tests for Hydra RDMA functionality.

## Quick Start

### Automated Build

```bash
# Complete automation: tmux, submodules, docker, assets, x86 package build
~/dev-notes/pensando-sw/scripts/build-hydra-vulcano-dol.sh

# With options
~/dev-notes/pensando-sw/scripts/build-hydra-vulcano-dol.sh --clean          # Clean before build
~/dev-notes/pensando-sw/scripts/build-hydra-vulcano-dol.sh --skip-submod    # Skip submodule update
~/dev-notes/pensando-sw/scripts/build-hydra-vulcano-dol.sh --skip-assets    # Skip pull-assets
~/dev-notes/pensando-sw/scripts/build-hydra-vulcano-dol.sh --clean-docker   # Clean Docker containers
```

## Manual Build (Inside Docker)

**Build x86 simulation package:**
```bash
cd /sw
make pull-assets
make -C nic PIPELINE=rudra P4_PROGRAM=hydra ARCH=x86_64 ASIC=vulcano package
```

**Verify build:**
```bash
ls -lh /sw/nic/build/x86_64/sim/rudra/vulcano/bin/pds_core_app
ls -lh /sw/nic/build/x86_64/sim/rudra/vulcano/bin/pds_dp_app
```

## Running DOL Tests

**Inside Docker at /sw/nic:**

### Single Test
```bash
cd /sw/nic

PIPELINE=rudra ASIC=vulcano P4_PROGRAM=hydra PCIEMGR_IF=1 DMA_MODE=uxdma PROFILE=qemu \
  rudra/test/tools/dol/rundol.sh \
  --pipeline rudra \
  --topo rdma_hydra \
  --feature rdma_hydra \
  --sub rdma_write \
  --nohntap
```

### Available Tests

Common RDMA test suites (--sub parameter):

| Test Name | Description |
|-----------|-------------|
| `rdma_write` | RDMA write operations |
| `rdma_read` | RDMA read operations |
| `rdma_send` | RDMA send operations |
| `rdma_atomic` | RDMA atomic operations |
| `rdma_all` | All RDMA tests |

**Test location:** `/sw/dol/rudra/test/rdma_hydra/`

### Environment Variables

| Variable | Value | Purpose |
|----------|-------|---------|
| `PIPELINE` | `rudra` | Pipeline name |
| `ASIC` | `vulcano` | ASIC type |
| `P4_PROGRAM` | `hydra` | P4 program name |
| `PCIEMGR_IF` | `1` | PCIe manager interface |
| `DMA_MODE` | `uxdma` | Unified DMA mode |
| `PROFILE` | `qemu` | Simulation profile |

## Test Execution Flow

1. **Setup** - `setup_dol.sh` configures environment
2. **Model Start** - Launches `vul_model` (hardware simulator)
3. **Process Start** - Starts `pds_core_app`, `pds_dp_app`
4. **Pre-test** - Waits for nicmgr initialization
5. **Test Run** - Executes Python DOL test scripts
6. **Cleanup** - Stops processes and model

## Logs and Debugging

### Log Locations

| Log | Location | Purpose |
|-----|----------|---------|
| DOL output | Console/stdout | Test results, assertions |
| Model | `/tmp/model.log` | vul_model simulator output |
| Nicmgr | `/obfl/nicmgr.log` | Nicmgr initialization |
| Nicmgr alt | `/var/log/pensando/nicmgr.log` | Alternative nicmgr log |
| Core dumps | `/tmp/core.*` | Crash dumps |

### Common Issues

**Test hangs waiting for nicmgr:**
```bash
# Check nicmgr logs
tail -100 /obfl/nicmgr.log | grep -i "init completed"

# Check nicmgr process
ps aux | grep nicmgr
```

**Model not responding:**
```bash
# Check model process
ps aux | grep vul_model

# Check model logs
tail -100 /tmp/model.log

# Kill and restart test
pkill -f vul_model
```

**Test fails with DMA errors:**
```bash
# Verify hugepages configured
cat /proc/meminfo | grep Huge

# Check DMA_MODE is set
echo $DMA_MODE  # Should be 'uxdma'
```

## Test Development

### Adding New Tests

1. Create test file in `/sw/dol/rudra/test/rdma_hydra/`
2. Follow existing test patterns (inherit from `DOLTestCase`)
3. Implement `setup()`, `trigger()`, `verify()` methods
4. Add to test suite configuration

### Example Test Structure

```python
from infra.common.dol import *

class RdmaWriteTest(DOLTestCase):
    def setup(self):
        # Setup QPs, memory regions, etc.
        pass

    def trigger(self):
        # Post work request
        pass

    def verify(self):
        # Verify completion, payload, etc.
        return True
```

## Clean Build

```bash
cd /sw
make clean
make -f Makefile.ainic clean

# Clean specific DOL artifacts
rm -rf /sw/nic/build/x86_64/sim/rudra/vulcano/
```

## Build Time

- **Clean build**: 20-30 minutes
- **Incremental**: 5-15 minutes

## References

- **Build target**: `nic/Makefile` (package target)
- **DOL runner**: `nic/rudra/test/tools/dol/rundol.sh`
- **DOL tests**: `/sw/dol/rudra/test/rdma_hydra/`
- **Setup script**: `nic/rudra/test/tools/dol/setup_dol.sh`
- **Profile config**: `/sw/dol/rudra/config/profile/hydra/host/qemu/profile.json`
