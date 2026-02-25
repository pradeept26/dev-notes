# Pensando SW - Development Context

## Repository
- Path: `/ws/pradeept/ws/usr/src/github.com/pensando/sw`
- Main branch: `master`
- Current work: `1x400g-breakout` branch

## Build Commands

### Standard Build
```bash
# TODO: Add your build command here
# Example: make PLATFORM=rudra TARGET=release
```

### Clean Build
```bash
# TODO: Add clean build steps
```

### Incremental Build
```bash
# TODO: Add incremental build if different
```

### Build Targets
- TODO: List common make targets
- TODO: Add any platform-specific builds

## Project Structure

### Key Directories
- `nic/rudra/` - RDMA/NIC code (recent changes in admincmd_handler.c)
- TODO: Add other important directories

### Important Files
- TODO: List frequently modified files
- TODO: Add config files or headers you reference often

## Hardware Setup

### Device Information
- TODO: Device IP/hostname
- TODO: SSH credentials or connection method
- TODO: Serial console access if applicable

### Loading Images to Hardware
```bash
# TODO: Add commands to load built image to hardware
# Example:
# scp build/image.bin user@device:/tmp/
# ssh user@device 'flash_tool /tmp/image.bin'
```

### Verification Steps
- TODO: How to verify image loaded correctly
- TODO: Common checks after deployment

## Testing

### Unit Tests
```bash
# TODO: Add unit test commands
```

### Integration Tests
```bash
# TODO: Add integration test commands
```

### Hardware Tests
- TODO: Describe hardware test workflow
- TODO: Test scripts or procedures

## Common Workflows

### Full Development Cycle
1. TODO: Edit code
2. TODO: Build
3. TODO: Run tests
4. TODO: Load to hardware
5. TODO: Verify

### Debugging
- TODO: Debug tools (gdb, logs, etc.)
- TODO: Common debugging commands
- TODO: Log file locations

## Dependencies

### Required Tools
- TODO: List required build tools
- TODO: Compiler versions
- TODO: Other dependencies

### Environment Setup
```bash
# TODO: Any environment variables needed
# TODO: Path setup
```

## Notes
- Recent work: 1x400g-4 breakout implementation
- Modified: `nic/rudra/src/hydra/nicmgr/plugin/rdma/admincmd_handler.c`

## Useful Commands
```bash
# TODO: Add frequently used commands
# Examples: status checks, quick rebuilds, common git operations
```

---
Last updated: 2026-02-25
