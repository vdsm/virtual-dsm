#!/usr/bin/env bash
set -Eeuo pipefail

: "${APP:="Virtual DSM"}"
: "${SUPPORT:="https://github.com/vdsm/virtual-dsm"}"

cd /run

. utils.sh      # Load functions
. reset.sh      # Initialize system
. install.sh    # Run installation
. disk.sh       # Initialize disks
. display.sh    # Initialize graphics
. network.sh    # Initialize network
. proc.sh       # Initialize processor
. serial.sh     # Initialize serialport
. power.sh      # Configure shutdown
. config.sh     # Configure arguments

trap - ERR

version=$(qemu-system-x86_64 --version | head -n 1 | cut -d '(' -f 1 | awk '{ print $NF }')
info "Booting $APP using QEMU v$version..."

if [[ "$CONSOLE" == [Yy]* ]]; then
  exec qemu-system-x86_64 ${ARGS:+ $ARGS}
fi

{ qemu-system-x86_64 ${ARGS:+ $ARGS} >"$QEMU_OUT" 2>"$QEMU_LOG"; rc=$?; } || :
(( rc != 0 )) && error "$(<"$QEMU_LOG")" && exit 15

terminal
tail -fn +0 "$QEMU_LOG" 2>/dev/null &
cat "$QEMU_TERM" 2>/dev/null & wait $! || :

sleep 1 & wait $!
[ ! -f "$QEMU_END" ] && finish 0
