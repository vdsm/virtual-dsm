#!/usr/bin/env bash
set -Eeuo pipefail

echo "❯ Starting Virtual DSM for Docker v${VERSION}..."
echo "❯ For support visit https://github.com/vdsm/virtual-dsm/"

. /run/reset.sh   # Initialize system
. /run/install.sh   # Run installation
. /run/disk.sh     # Initialize disks
. /run/gpu.sh     # Initialize graphics
. /run/network.sh  # Initialize network
. /run/serial.sh   # Initialize serialport
. /run/power.sh    # Configure shutdown
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
