# DOL Testing Quick Reference

**Copy/paste for inside Docker**

## Build Command (at /sw)

```bash
cd /sw

# Build x86 simulation package
make -C nic PIPELINE=rudra P4_PROGRAM=hydra ARCH=x86_64 ASIC=vulcano package

# Verify binaries
ls -lh /sw/nic/build/x86_64/sim/rudra/vulcano/bin/pds_core_app
ls -lh /sw/nic/build/x86_64/sim/rudra/vulcano/bin/pds_dp_app
```

## Run DOL Tests (at /sw/nic)

```bash
cd /sw/nic

# RDMA Write test
PIPELINE=rudra ASIC=vulcano P4_PROGRAM=hydra PCIEMGR_IF=1 DMA_MODE=uxdma PROFILE=qemu \
  rudra/test/tools/dol/rundol.sh \
  --pipeline rudra \
  --topo rdma_hydra \
  --feature rdma_hydra \
  --sub rdma_write \
  --nohntap

# RDMA Read test
PIPELINE=rudra ASIC=vulcano P4_PROGRAM=hydra PCIEMGR_IF=1 DMA_MODE=uxdma PROFILE=qemu \
  rudra/test/tools/dol/rundol.sh \
  --pipeline rudra \
  --topo rdma_hydra \
  --feature rdma_hydra \
  --sub rdma_read \
  --nohntap

# RDMA Send test
PIPELINE=rudra ASIC=vulcano P4_PROGRAM=hydra PCIEMGR_IF=1 DMA_MODE=uxdma PROFILE=qemu \
  rudra/test/tools/dol/rundol.sh \
  --pipeline rudra \
  --topo rdma_hydra \
  --feature rdma_hydra \
  --sub rdma_send \
  --nohntap
```

## Available Tests

- `rdma_write` - RDMA write operations
- `rdma_read` - RDMA read operations
- `rdma_send` - RDMA send operations
- `rdma_atomic` - RDMA atomic operations
- `rdma_all` - All RDMA tests

## Logs

```bash
# Test output - console/stdout
# Model logs
tail -100 /tmp/model.log

# Nicmgr logs
cat /obfl/nicmgr.log
```

## Outside Docker

```bash
# Build automation
~/dev-notes/pensando-sw/scripts/build-hydra-vulcano-dol.sh

# Tests must be run inside Docker manually
```
