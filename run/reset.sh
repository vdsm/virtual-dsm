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

KERNEL=$(uname -r | cut -b 1)
MINOR=$(uname -r | cut -d '.' -f2)
ARCH=$(dpkg --print-architecture)
VERS=$(qemu-system-x86_64 --version | head -n 1 | cut -d '(' -f 1)

rm -f /run/dsm.url
rm -f /run/qemu.pid
rm -f /run/qemu.count
