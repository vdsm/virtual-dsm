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

. /run/reset.sh   # Cleanup files
. /run/install.sh   # Run installation
. /run/disk.sh     # Initialize disks
. /run/gpu.sh     # Initialize graphics
. /run/network.sh  # Initialize network
. /run/serial.sh   # Initialize serialport
. /run/power.sh    # Configure shutdown

KVM_ERR=""
KVM_OPTS=""

if [ -e /dev/kvm ] && sh -c 'echo -n > /dev/kvm' &> /dev/null; then
  if ! grep -q -e vmx -e svm /proc/cpuinfo; then
    KVM_ERR="(vmx/svm disabled)"
  fi
else
  [ -e /dev/kvm ] && KVM_ERR="(no write access)" || KVM_ERR="(device file missing)"
fi

if [ -n "${KVM_ERR}" ]; then
  if [ "$ARCH" == "amd64" ]; then
    error "KVM acceleration not detected ${KVM_ERR}, see the FAQ about this."
    [[ "${DEBUG}" != [Yy1]* ]] && exit 88
  fi
else
  KVM_OPTS=",accel=kvm -enable-kvm -cpu host"
fi

DEF_OPTS="-nographic -nodefaults -boot strict=on -display none"
RAM_OPTS=$(echo "-m ${RAM_SIZE}" | sed 's/MB/M/g;s/GB/G/g;s/TB/T/g')
CPU_OPTS="-smp ${CPU_CORES},sockets=1,dies=1,cores=${CPU_CORES},threads=1"
MAC_OPTS="-machine type=q35,usb=off,dump-guest-core=off,hpet=off${KVM_OPTS}"
EXTRA_OPTS="-device virtio-balloon-pci,id=balloon0,bus=pcie.0,addr=0x4"
EXTRA_OPTS="$EXTRA_OPTS -object rng-random,id=objrng0,filename=/dev/urandom"
EXTRA_OPTS="$EXTRA_OPTS -device virtio-rng-pci,rng=objrng0,id=rng0,bus=pcie.0,addr=0x1c"

if [[ "${GPU}" == [Yy1]* ]] && [[ "$ARCH" == "amd64" ]]; then
  DEF_OPTS="-nodefaults -boot strict=on -display egl-headless,rendernode=/dev/dri/renderD128"
  DEF_OPTS="${DEF_OPTS} -device virtio-vga,id=video0,max_outputs=1,bus=pcie.0,addr=0x1"
fi

ARGS="${DEF_OPTS} ${CPU_OPTS} ${RAM_OPTS} ${MAC_OPTS} ${MON_OPTS} ${SERIAL_OPTS} ${NET_OPTS} ${DISK_OPTS} ${EXTRA_OPTS} ${ARGUMENTS}"
ARGS=$(echo "$ARGS" | sed 's/\t/ /g' | tr -s ' ')

trap - ERR

set -m
(
  [[ "${DEBUG}" == [Yy1]* ]] && info "$VERS" && set -x
  qemu-system-x86_64 ${ARGS:+ $ARGS} & echo $! > "${QEMU_PID}"
  { set +x; } 2>/dev/null
)
set +m

tail --pid "$(cat "${QEMU_PID}")" --follow /dev/null & wait $!
