# Pensando Hydra Development - Quick Start

## Simplified Workflow Commands

When working with Claude Code, use these simple commands - Claude will execute complete workflows without asking questions.

### Build Commands

```bash
# Build hardware firmware
"build hw"

# Clean build from scratch
"clean hw build"

# Build simulator/DOL version
"build sim"

# Build gtests
"build gtest"
```

### IB/RDMA Testing

```bash
# Basic 4 QP test
"run ib test"

# Stress test for MSN window validation
"test msn window"

# Comprehensive benchmark with Excel
"ib benchmark"

# Direct script usage (more control)
~/dev-notes/pensando-sw/scripts/run-ib-test.sh smc1-smc2 --qp 8 --xlsx
```

### Deployment

```bash
# Deploy to SMC1
"deploy to smc1"

# Deploy to SMC2
"deploy to smc2"

# Deploy to both
"deploy everywhere"
```

### Git

```bash
# Auto-commit with generated message
"commit changes"
```

---

## Behind the Scenes

Claude automatically:
- ✅ Uses tmux session `pensando-sw` for builds
- ✅ Manages docker containers
- ✅ Pulls assets when needed
- ✅ Cleans workspace before builds
- ✅ Runs commands at correct locations (/sw in docker)
- ✅ Reports results concisely

---

## Current Experiment: MSN Context Reduction

**Changes Made:**
- Reduced MSN tracking window: 256 → 128 entries
- Memory savings: 50% per QP (2048 → 1024 bytes)
- QP capacity doubled: 1024 → 2048 QPs in same 2MB region

**Files Modified (6):**
1. admincmd_handler.c - Constant
2. meta_roce_defines.p4 - Constant
3. rdma_rqcb.p4 - Structure
4. rdma_sqcb.p4 - Structure
5. meta_roce_rx_s5.p4 - FFV logic
6. meta_roce_tx_s5.p4 - FFV logic

**Status:**
- ✅ Hardware firmware built successfully
- 🔄 Ready for hardware testing
- 📊 Can run IB benchmarks to validate

---

## Key Files

- **Workflow shortcuts:** `.claude/CLAUDE.md`
- **IB test wrapper:** `~/dev-notes/pensando-sw/scripts/run-ib-test.sh`
- **IB testing guide:** `~/dev-notes/pensando-sw/ib-testing-guide.md`
- **This quickstart:** `~/dev-notes/pensando-sw/QUICKSTART.md`

---

## Hardware Setup

**SMC1:** 10.30.75.198 (ubuntu/amd123) - 8 Vulcano NICs
**SMC2:** 10.30.75.204 (ubuntu/amd123) - 8 Vulcano NICs

---

## Documentation

Full context: `~/dev-notes/pensando-sw/context.md`
Hardware setups: `~/dev-notes/pensando-sw/hardware/vulcano/`
