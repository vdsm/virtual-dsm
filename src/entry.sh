#!/usr/bin/env bash
set -Eeuo pipefail

: "${PLATFORM:="x64"}"
: "${APP:="Virtual DSM"}"
: "${SUPPORT:="https://github.com/vdsm/virtual-dsm"}"

cd /run

. start.sh      # Startup hook
. utils.sh      # Load functions
. reset.sh      # Initialize system
. server.sh     # Start webserver
. install.sh    # Run installation
. disk.sh       # Initialize disks
. display.sh    # Initialize graphics
. network.sh    # Initialize network
. proc.sh       # Initialize processor
. serial.sh     # Initialize serialport
. power.sh      # Configure shutdown
. memory.sh     # Check available memory
. config.sh     # Configure arguments
. finish.sh     # Finish initialization

trap - ERR

cmd=(qemu-system-x86_64)
version=$("${cmd[@]}" --version | awk 'NR==1 { print $4 }')
info "Booting $APP using QEMU v$version..."

if [[ "$SHUTDOWN" != [Yy1]* ]]; then
  exec "${cmd[@]}" ${ARGS:+ $ARGS}
fi

if [ ! -t 1 ] || [ ! -c /dev/tty ]; then
  "${cmd[@]}" ${ARGS:+ $ARGS} &
else
  "${cmd[@]}" ${ARGS:+ $ARGS} </dev/tty >/dev/tty &
fi

rc=0
wait $! || rc=$?
[ -f "$QEMU_END" ] && exit "$rc"

sleep 1 & wait $!
finish "$rc"
