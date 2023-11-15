#!/usr/bin/env bash
set -Eeuo pipefail

info () { echo -e "\E[1;34m❯ \E[1;36m$1\E[0m" ; }
error () { echo -e >&2 "\E[1;31m❯ ERROR: $1\E[0m" ; }
trap 'error "Status $? while: ${BASH_COMMAND} (line $LINENO/$BASH_LINENO)"' ERR

[ ! -f "/run/run.sh" ] && error "Script must run inside Docker container!" && exit 11
[ "$(id -u)" -ne "0" ] && error "Script must be executed with root privileges." && exit 12

# Docker environment variables

: ${URL:=''}            # URL of the PAT file
: ${GPU:='N'}           # Enable GPU passthrough
: ${DEBUG:='N'}         # Enable debugging mode
: ${ALLOCATE:='Y'}      # Preallocate diskspace
: ${ARGUMENTS:=''}      # Extra QEMU parameters
: ${CPU_CORES:='1'}     # Amount of CPU cores
: ${DISK_SIZE:='16G'}   # Initial data disk size
: ${RAM_SIZE:='512M'}   # Maximum RAM amount

# Helper variables

KERNEL=$(uname -r | cut -b 1)
MINOR=$(uname -r | cut -d '.' -f2)
ARCH=$(dpkg --print-architecture)
VERS=$(qemu-system-x86_64 --version | head -n 1 | cut -d '(' -f 1)

# Cleanup files

rm -f /run/dsm.url
rm -f /run/qemu.pid
rm -f /run/qemu.count

return 0
