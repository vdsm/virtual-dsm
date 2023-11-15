#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables

: ${URL:=''}            # URL of the PAT file
: ${GPU:='N'}           # Enable GPU passthrough
: ${DEBUG:='N'}         # Enable debugging mode
: ${ALLOCATE:='Y'}      # Preallocate diskspace
: ${ARGUMENTS:=''}      # Extra QEMU parameters
: ${CPU_CORES:='1'}     # Amount of CPU cores
: ${DISK_SIZE:='16G'}   # Initial data disk size
: ${RAM_SIZE:='512M'}   # Maximum RAM amount

echo "❯ Starting Virtual DSM for Docker v${VERSION}..."
echo "❯ For support visit https://github.com/vdsm/virtual-dsm/"

info () { echo -e "\E[1;34m❯ \E[1;36m$1\E[0m" ; }
error () { echo -e >&2 "\E[1;31m❯ ERROR: $1\E[0m" ; }
trap 'error "Status $? while: ${BASH_COMMAND} (line $LINENO/$BASH_LINENO)"' ERR

[ ! -f "/run/run.sh" ] && error "Script must run inside Docker container!" && exit 11
[ "$(id -u)" -ne "0" ] && error "Script must be executed with root privileges." && exit 12

. /run/reset.sh   # Initialize system
. /run/install.sh   # Run installation
. /run/disk.sh     # Initialize disks
. /run/gpu.sh     # Initialize graphics
. /run/network.sh  # Initialize network
. /run/serial.sh   # Initialize serialport
. /run/power.sh    # Configure shutdown
. /run/config.sh    # Configure QEMU

trap - ERR

set -m
(
  [[ "${DEBUG}" == [Yy1]* ]] && info "$VERS" && set -x
  qemu-system-x86_64 ${ARGS:+ $ARGS} & echo $! > "${QEMU_PID}"
  { set +x; } 2>/dev/null
)
set +m

tail --pid "$(cat "${QEMU_PID}")" --follow /dev/null & wait $!
