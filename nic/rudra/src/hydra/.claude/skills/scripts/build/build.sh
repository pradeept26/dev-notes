#!/bin/bash
# Build AINIC firmware
# Usage: ./build.sh <asic> <p4-program> [platform] [options] [container-id]
#
# Arguments:
#   asic        - ASIC type: vulcano or salina
#   p4-program  - P4 program: hydra or pulsar
#   platform    - Platform (optional): hw, sim, sw-emu, host-tools, nicctl, asicmon, dbg-tools, ethdbgtool. Default: hw
#   container-id - Docker container ID (optional, auto-detected if not provided)
#
# Options:
#   -c, --clean   Clean build files before building
#   --clean-only  Only clean build files, don't build
#
# Environment variables:
#   HYDRA_CONTAINER - Default Docker container ID. Used when no container-id arg is passed
#                     and auto-detection finds zero or multiple containers. Overridden by
#                     an explicit container-id arg.
#   HYDRA_SW        - Host workspace path containing the pensando/sw checkout (used in
#                     error messages). Defaults to ~/ws/sw/nic.
#
# Examples:
#   ./build.sh vulcano hydra
#   ./build.sh vulcano hydra hw
#   ./build.sh salina pulsar sim
#   ./build.sh vulcano hydra hw --clean
#   ./build.sh salina hydra hw --clean-only
#   ./build.sh vulcano hydra hw abc123def
#   ./build.sh salina hydra host-tools    # Build all host tools (nicctl, drivers, etc.)
#   ./build.sh salina hydra nicctl        # Build only nicctl (faster)

set -e

# Function to show usage
usage() {
    cat << EOF
Usage: $0 <asic> <p4-program> [platform] [options] [container-id]

Arguments:
  asic        - ASIC type: vulcano or salina
  p4-program  - P4 program: hydra or pulsar
  platform    - Platform (optional): hw, sim, sw-emu, host-tools, nicctl, asicmon, dbg-tools, ethdbgtool. Default: hw
  container-id - Docker container ID (optional, auto-detected if not provided)

Options:
  -c, --clean   Clean build files before building
  --clean-only  Only clean build files, don't build

Examples:
  $0 vulcano hydra
  $0 vulcano hydra hw
  $0 salina pulsar sim
  $0 vulcano hydra hw --clean
  $0 salina hydra hw --clean-only
  $0 vulcano hydra hw abc123def
  $0 salina hydra host-tools    # Build all host tools (nicctl, drivers, etc.)
  $0 salina hydra nicctl        # Build only nicctl (faster)
  $0 vulcano hydra asicmon      # Build only asicmon (vulcanomon)
  $0 vulcano hydra dbg-tools    # Build all debug tools (eth_dbgtool, mputrace, etc.)
  $0 vulcano hydra ethdbgtool   # Build only eth_dbgtool

EOF
    exit 1
}

# Check for help flag first
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    usage
fi

# Check minimum arguments
if [ $# -lt 2 ]; then
    echo "Error: Missing required arguments"
    usage
fi

ASIC="$1"
P4_PROGRAM="$2"
shift 2

# Parse remaining arguments
PLATFORM="hw"
CONTAINER_ID=""
DO_CLEAN=false
CLEAN_ONLY=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--clean)
            DO_CLEAN=true
            shift
            ;;
        --clean-only)
            DO_CLEAN=true
            CLEAN_ONLY=true
            shift
            ;;
        -*)
            echo "Error: Unknown option '$1'"
            usage
            ;;
        *)
            # First positional arg is platform, second is container-id
            if [[ -z "$PLATFORM" || "$PLATFORM" == "hw" ]]; then
                # Check if it looks like a container ID (hex string) or a platform
                if [[ "$1" =~ ^[a-f0-9]+$ && ${#1} -ge 6 ]]; then
                    CONTAINER_ID="$1"
                else
                    PLATFORM="$1"
                fi
            else
                CONTAINER_ID="$1"
            fi
            shift
            ;;
    esac
done

# Validate ASIC
if [[ "$ASIC" != "vulcano" && "$ASIC" != "salina" ]]; then
    echo "Error: Invalid ASIC '$ASIC'. Must be 'vulcano' or 'salina'"
    usage
fi

# Validate P4_PROGRAM
if [[ "$P4_PROGRAM" != "hydra" && "$P4_PROGRAM" != "pulsar" ]]; then
    echo "Error: Invalid P4 program '$P4_PROGRAM'. Must be 'hydra' or 'pulsar'"
    usage
fi

# Find container if not provided
if [ -z "$CONTAINER_ID" ]; then
    SCRIPT_DIR_BUILD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$SCRIPT_DIR_BUILD/../lib/docker_utils.sh"
    find_pensando_container || exit 1
fi

echo "Using container: $CONTAINER_ID"

# Docker exec with user flag
DOCKER_EXEC="docker exec -u $USER"

# Ensure git safe directory is configured
$DOCKER_EXEC "$CONTAINER_ID" git config --global --add safe.directory /sw 2>/dev/null || true

# Function to clean build files
do_clean() {
    echo "Cleaning build files for $ASIC..."
    # Use sudo for clean since build files may be owned by root (from container builds)
    DOCKER_EXEC_SUDO="docker exec"
    if [[ "$ASIC" == "salina" ]]; then
        # Salina clean: remove build directories directly
        $DOCKER_EXEC_SUDO -w /sw "$CONTAINER_ID" rm -rf /sw/nic/build /sw/nic/rudra/build /sw/nic/conf/gen /sw/platform/rtos-sw/build
        echo "Clean complete."
    elif [[ "$ASIC" == "vulcano" ]]; then
        # Vulcano clean: use Makefile.ainic clean target with sudo
        $DOCKER_EXEC_SUDO -w /sw "$CONTAINER_ID" make -f Makefile.ainic clean
        echo "Clean complete."
    fi
}

# Clean if requested
if [[ "$DO_CLEAN" == true ]]; then
    do_clean
    if [[ "$CLEAN_ONLY" == true ]]; then
        echo "Clean-only mode, skipping build."
        exit 0
    fi
fi

# Determine the make target and command based on ASIC and platform
if [[ "$ASIC" == "vulcano" ]]; then
    if [[ "$PLATFORM" == "hw" ]]; then
        MAKE_TARGET="rudra-vulcano-ainic-fw"
    elif [[ "$PLATFORM" == "host-tools" ]]; then
        MAKE_TARGET="rudra-vulcano-ainic-host-tools"
    elif [[ "$PLATFORM" == "nicctl" ]]; then
        # Build only nicctl (faster, no driver packages)
        MAKE_TARGET="nicctl.bin"
    elif [[ "$PLATFORM" == "asicmon" ]]; then
        # Build only asicmon/vulcanomon
        MAKE_TARGET="vulcanomon.bin"
    elif [[ "$PLATFORM" == "dbg-tools" ]]; then
        # Build all debug tools (eth_dbgtool, mputrace, capview, etc.)
        MAKE_TARGET="rudra-ainic-dbg-tools-bin"
    elif [[ "$PLATFORM" == "ethdbgtool" ]]; then
        # Build only eth_dbgtool
        MAKE_TARGET="ethdbgtool-bin"
    elif [[ "$PLATFORM" == "sim" ]]; then
        # For Vulcano, sim uses sw-emu target
        MAKE_TARGET="rudra-vulcano-${P4_PROGRAM}-sw-emu"
    else
        # For sw-emu, etc.
        MAKE_TARGET="rudra-vulcano-${P4_PROGRAM}-${PLATFORM}"
    fi
    # Vulcano uses Makefile.ainic (except nicctl and asicmon which use nic/Makefile)
    if [[ "$PLATFORM" == "nicctl" ]]; then
        MAKE_CMD="make -C nic ASIC=$ASIC PIPELINE=rudra ARCH=x86_64 PLATFORM=hw PRODUCT_FAMILY=ainic P4_PROGRAM=$P4_PROGRAM $MAKE_TARGET"
    elif [[ "$PLATFORM" == "asicmon" ]]; then
        MAKE_CMD="make -C nic ASIC=$ASIC PIPELINE=rudra ARCH=x86_64 PLATFORM=hw P4_PROGRAM=$P4_PROGRAM $MAKE_TARGET"
    elif [[ "$PLATFORM" == "dbg-tools" || "$PLATFORM" == "ethdbgtool" ]]; then
        # dbg-tools and ethdbgtool use Makefile.ainic
        MAKE_CMD="make ASIC=$ASIC P4_PROGRAM=$P4_PROGRAM -f Makefile.ainic $MAKE_TARGET"
    else
        MAKE_CMD="make P4_PROGRAM=$P4_PROGRAM -f Makefile.ainic $MAKE_TARGET"
    fi
elif [[ "$ASIC" == "salina" ]]; then
    if [[ "$PLATFORM" == "hw" ]]; then
        MAKE_TARGET="rudra-salina-ainic-a35-fw"
    elif [[ "$PLATFORM" == "host-tools" ]]; then
        MAKE_TARGET="rudra-salina-ainic-host-tools"
    elif [[ "$PLATFORM" == "nicctl" ]]; then
        # Build only nicctl (faster, no driver packages)
        MAKE_TARGET="nicctl.bin"
    elif [[ "$PLATFORM" == "asicmon" ]]; then
        # Build only asicmon/salinamon
        MAKE_TARGET="salinamon.bin"
    elif [[ "$PLATFORM" == "dbg-tools" ]]; then
        # Build all debug tools (eth_dbgtool, mputrace, capview, etc.)
        MAKE_TARGET="rudra-ainic-dbg-tools-bin"
    elif [[ "$PLATFORM" == "ethdbgtool" ]]; then
        # Build only eth_dbgtool
        MAKE_TARGET="ethdbgtool-bin"
    elif [[ "$PLATFORM" == "sim" ]]; then
        # Salina sim: produces the model + zephyr.exe needed by DOL
        # (PROFILE=zephyr). Equivalent to `build-zephyr-salina-${P4_PROGRAM}-sim`
        # in Makefile.build but inlines `build-salina-model` and skips both tar/du
        # packaging steps (those tarballs are only consumed by CI .job.yml files).
        MAKE_TARGET="salina sim model + zephyr.exe + hydra_gtest{,_aq} (no-tar)"
    else
        MAKE_TARGET="rudra-salina-${P4_PROGRAM}-${PLATFORM}"
    fi
    # Salina uses the main Makefile (except nicctl/asicmon/sim which use other Makefiles)
    if [[ "$PLATFORM" == "nicctl" ]]; then
        MAKE_CMD="make -C nic ASIC=$ASIC PIPELINE=rudra ARCH=x86_64 PLATFORM=hw PRODUCT_FAMILY=ainic SALINA_PHV=true P4_PROGRAM=$P4_PROGRAM $MAKE_TARGET"
    elif [[ "$PLATFORM" == "asicmon" ]]; then
        MAKE_CMD="make -C nic ASIC=$ASIC PIPELINE=rudra ARCH=x86_64 PLATFORM=hw SALINA_PHV=true P4_PROGRAM=$P4_PROGRAM $MAKE_TARGET"
    elif [[ "$PLATFORM" == "sim" ]]; then
        # Multi-step inside container; use bash -c so && runs in-container.
        # `make -C nic ... package` is nic/Makefile's default goal — it builds
        # all sim libs, sal_model.bin, model_sim_cli.bin, AND the gtest binaries
        # (hydra_gtest / hydra_gtest_aq) under
        # nic/rudra/build/${P4_PROGRAM}/x86_64/sim/rudra/salina/bin/. There is no
        # `rudra-salina-hydra-gtest` target in Makefile.ainic (only the vulcano
        # equivalent at Makefile.ainic:400), so `package` is the simplest path
        # to all artifacts on salina.
        # NOTE: pull-assets-ainic-rudra-salina[-sim] live in the main /sw/Makefile,
        # not Makefile.build, so they're invoked with plain `make` (no -f).
        MAKE_CMD="bash -c '\
            make pull-assets-ainic-rudra-salina-sim pull-assets-ainic-rudra-salina && \
            make -C nic PIPELINE=rudra P4_PROGRAM=${P4_PROGRAM} ASIC=salina ARCH=x86_64 package && \
            make -C platform/rtos-sw P4_PROGRAM=${P4_PROGRAM} build-rtos-salina_sim-ainic'"
    elif [[ "$PLATFORM" == "dbg-tools" || "$PLATFORM" == "ethdbgtool" ]]; then
        # dbg-tools and ethdbgtool use Makefile.ainic
        MAKE_CMD="make ASIC=$ASIC P4_PROGRAM=$P4_PROGRAM -f Makefile.ainic $MAKE_TARGET"
    else
        MAKE_CMD="make P4_PROGRAM=$P4_PROGRAM $MAKE_TARGET"
    fi
fi

echo "Building AINIC $ASIC $P4_PROGRAM ($PLATFORM)..."
echo "Make target: $MAKE_TARGET"

# Execute the build command. Use eval so embedded quoting in $MAKE_CMD
# (e.g. salina sim's `bash -c '...'`) is honored when run inside the container.
FULL_CMD="$DOCKER_EXEC -w /sw $CONTAINER_ID $MAKE_CMD"
echo "Executing: $FULL_CMD"
eval "$FULL_CMD"

echo ""
echo "Done! Build artifacts location:"
if [[ "$PLATFORM" == "hw" ]]; then
    if [[ "$ASIC" == "vulcano" ]]; then
        echo "  /sw/nic/rudra/build/${P4_PROGRAM}/aarch64/hw/rudra/vulcano/"
    else
        echo "  /sw/nic/rudra/build/${P4_PROGRAM}/aarch64/hw/rudra/salina/"
    fi
elif [[ "$PLATFORM" == "host-tools" || "$PLATFORM" == "nicctl" ]]; then
    echo "  /sw/nic/build/x86_64/hw/rudra/${ASIC}/bin/nicctl"
elif [[ "$PLATFORM" == "dbg-tools" ]]; then
    echo "  /sw/nic/rudra/build/${P4_PROGRAM}/x86_64/hw/rudra/${ASIC}/bin/eth_dbgtool_rudra"
    echo "  /sw/nic/build/x86_64/hw/rudra/${ASIC}/bin/vultrace"
    echo "  /sw/nic/build/x86_64/hw/rudra/${ASIC}/bin/vulcanomon"
elif [[ "$PLATFORM" == "ethdbgtool" ]]; then
    echo "  /sw/nic/rudra/build/${P4_PROGRAM}/x86_64/hw/rudra/${ASIC}/bin/eth_dbgtool_rudra"
elif [[ "$PLATFORM" == "asicmon" ]]; then
    if [[ "$ASIC" == "vulcano" ]]; then
        echo "  /sw/nic/build/x86_64/hw/rudra/vulcano/out/vulcanomon_bin/vulcanomon.bin"
    else
        echo "  /sw/nic/build/x86_64/hw/rudra/salina/out/salinamon_bin/salinamon.bin"
    fi
elif [[ "$ASIC" == "salina" && "$PLATFORM" == "sim" ]]; then
    echo "  /sw/platform/rtos-sw/build/zephyr/zephyr.exe"
    echo "  /sw/nic/rudra/build/${P4_PROGRAM}/x86_64/sim/rudra/salina/"
else
    echo "  /sw/nic/rudra/build/${P4_PROGRAM}/x86_64/${PLATFORM}/rudra/${ASIC}/"
fi
