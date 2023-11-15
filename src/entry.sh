#!/usr/bin/env bash
set -Eeuo pipefail

echo "❯ Starting Virtual DSM for Docker v${VERSION}..."
echo "❯ For support visit https://github.com/vdsm/virtual-dsm/"

# shellcheck source=./reset.sh
. /run/reset.sh   # Initialize system

# shellcheck source=./install.sh
. /run/install.sh   # Run installation

# shellcheck source=./disk.sh
. /run/disk.sh     # Initialize disks

# shellcheck source=./network.sh
. /run/network.sh  # Initialize network

# shellcheck source=./gpu.sh
. /run/gpu.sh     # Initialize graphics

# shellcheck source=./serial.sh
. /run/serial.sh   # Initialize serialport

# shellcheck source=./power.sh
. /run/power.sh    # Configure shutdown

# shellcheck source=./config.sh
. /run/config.sh    # Configure arguments

trap - ERR

set -m
(
  [[ "${DEBUG}" == [Yy1]* ]] && info "$VERS" && set -x
  qemu-system-x86_64 ${ARGS:+ $ARGS} & echo $! > "${QEMU_PID}"
  { set +x; } 2>/dev/null
)
set +m

tail --pid "$(cat "${QEMU_PID}")" --follow /dev/null & wait $!
