#!/usr/bin/env bash
set -Eeuo pipefail

echo "❯ Starting Virtual DSM for Docker v$(</run/version)..."
echo "❯ For support visit https://github.com/vdsm/virtual-dsm/"

cd /run

. reset.sh      # Initialize system
. install.sh    # Run installation
. disk.sh       # Initialize disks
. network.sh    # Initialize network
. gpu.sh        # Initialize graphics
. serial.sh     # Initialize serialport
. power.sh      # Configure shutdown
. config.sh     # Configure arguments

trap - ERR

if [[ "${CONSOLE}" == [Yy]* ]]; then
  info "$VERS" && set -x
  exec qemu-system-x86_64 -pidfile "${QEMU_PID}" ${ARGS:+ $ARGS}
  exit $?
fi

set -m
(
  [[ "${DEBUG}" == [Yy1]* ]] && info "$VERS" && set -x
  qemu-system-x86_64 ${ARGS:+ $ARGS} & echo $! > "${QEMU_PID}"
  { set +x; } 2>/dev/null
)
set +m

tail --pid "$(cat "${QEMU_PID}")" --follow /dev/null & wait $!
