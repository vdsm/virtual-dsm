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
msg=$(qemu-system-x86_64 -daemonize -pidfile "$QEMU_PID" ${ARGS:+ $ARGS})
{ set +x; } 2>/dev/null

if [[ "$msg" != "char"* ||  "$msg" != *"serial0)" ]]; then
  echo "$msg"
fi

dev="${msg#*/dev/p}"
dev="/dev/p${dev%% *}"

if [ ! -c "$dev" ]; then
  dev=$(echo 'info chardev' | nc -q 1 -w 1 localhost "$QEMU_PORT" | tr -d '\000')
  dev="${dev#*charserial0}"
  dev="${dev#*pty:}"
  dev="${dev%%$'\n'*}"
  dev="${dev%%$'\r'*}"
fi

if [ ! -c "$dev" ]; then
  error "Device `$dev` not found!"
  finish 34
fi

cat "$dev" 2>/dev/null & wait $! || true

sleep 1
finish 0
