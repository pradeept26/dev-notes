# Firmware Build Quick Reference

**Copy/paste for inside Docker**

## Build Command (at /sw)

```bash
cd /sw

# Full firmware
make -f Makefile.ainic P4_PROGRAM=hydra rudra-vulcano-ainic-fw

# Variant (m5 most common)
make -f Makefile.ainic P4_PROGRAM=hydra rudra-vulcano-ainic-fw-m5

# Check output
ls -lh /sw/ainic_fw_vulcano.tar
ls -lh /sw/ainic_fw_vulcano.pldmfw
```

## Deploy to Hardware

```bash
# Copy to host
scp /sw/ainic_fw_vulcano.tar ubuntu@10.30.75.198:/tmp/

# SSH to host and update
ssh ubuntu@10.30.75.198
sudo nicctl update firmware -i /tmp/ainic_fw_vulcano.tar
sudo nicctl reset card --all

# Wait 30s, then verify
sleep 30
sudo nicctl show card
sudo nicctl show version
```

## Module Variants

| Variant | Modules |
|---------|---------|
| (default) | All modules |
| m1 | pciemgr, devmgr |
| m2 | devmgr, nicmgr |
| m3 | pciemgr, devmgr, nicmgr |
| m4 | + qosmgr |
| m5 | + linkmgr, hwmon (recommended) |
| m6 | pciemgr, devmgr, linkmgr |
| gold | Gold/recovery firmware |

## Outside Docker

```bash
# Full automation
~/dev-notes/pensando-sw/scripts/build-hydra-firmware.sh

# With variant
~/dev-notes/pensando-sw/scripts/build-hydra-firmware.sh --variant m5
```
