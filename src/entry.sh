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
. cpu.sh        # Initialize processor
. serial.sh     # Initialize serialport
. power.sh      # Configure shutdown
. config.sh     # Configure arguments

trap - ERR

if [[ "$CONSOLE" == [Yy]* ]]; then
  exec qemu-system-x86_64 -pidfile "$QEMU_PID" ${ARGS:+ $ARGS}
  exit $?
fi

[[ "$DEBUG" == [Yy1]* ]] && info "$VERS" && set -x
qemu-system-x86_64 -daemonize -pidfile "$QEMU_PID" ${ARGS:+ $ARGS}

{ set +x; } 2>/dev/null
cat /dev/pts/1 2>/dev/null & wait $! || true

finish "0"
