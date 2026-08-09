#!/usr/bin/env bash
set -Eeuo pipefail

: "${PLATFORM:="x64"}"
: "${APP:="Virtual DSM"}"
: "${SUPPORT:="https://github.com/vdsm/virtual-dsm"}"

: "${USB:="N"}"
: "${AUDIO:="N"}"
: "${VGA:="none"}"
: "${DISPLAY:="none"}"
: "${WEB_PORT:="5000"}"
: "${DISK_OFFSET:="2"}"
: "${DISK_SIZE:="256G"}"
: "${RAM_MINIMUM:="1G"}"
: "${DISK_MINIMUM:="6G"}"
: "${BOOT_MODE:="legacy"}"

cd /run

. start.sh      # Startup hook
. utils.sh      # Load functions
. init.sh       # Initialize system
. memory.sh     # Check memory
. server.sh     # Start webserver
. install.sh    # Run installation
. disk.sh       # Initialize disks
. display.sh    # Initialize graphics
. prepare.sh    # Prepare for launch
. network.sh    # Initialize network
. boot.sh       # Configure boot
. proc.sh       # Initialize processor
. serial.sh     # Initialize serialport
. power.sh      # Configure shutdown
. balloon.sh    # Initialize ballooning
. config.sh     # Configure arguments
. finish.sh     # Finish initialization

trap - ERR

cmd=(qemu-system-x86_64)
version=$("${cmd[@]}" --version | awk 'NR==1 { print $4 }')
info "Booting $APP using QEMU v$version..." && echo

if ! enabled "$SHUTDOWN"; then
  exec "${cmd[@]}" ${ARGS:+ $ARGS}
fi

if ! interactive; then
  "${cmd[@]}" ${ARGS:+ $ARGS} &
else
  startConsole
  startQemu "${cmd[@]}" ${ARGS:+ $ARGS}
fi

pid=$!
rc=0

wait "$pid" || rc=$?
[ -f "$QEMU_END" ] && exit "$rc"

sleep 1 & wait $!
finish "$rc"
