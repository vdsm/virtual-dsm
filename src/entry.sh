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
dev=$(qemu-system-x86_64 -daemonize -pidfile "$QEMU_PID" ${ARGS:+ $ARGS})
{ set +x; } 2>/dev/null

if [[ "$dev" != *"redirected to /dev/"* ]]; then
  error "$dev"
  finish 33
fi

dev="${dev#*redirected to /dev/}"
dev="/dev/${dev%% *}"

if [ ! -c "$dev" ]; then
  error "Device $dev not found!"
  finish 34
fi

cat "$dev" & wait $! || true

sleep 1
finish 0
