#!/usr/bin/env bash
set -eu

echo "Starting Virtual DSM for Docker v${VERSION}..."

STORAGE="/storage"
[ ! -d "$STORAGE" ] && echo "Storage folder (${STORAGE}) not found!" && exit 69
[ ! -f "/run/run.sh" ] && echo "Script must run inside Docker container!" && exit 60

if [ -f "$STORAGE"/dsm.ver ]; then
  BASE=$(cat "${STORAGE}/dsm.ver")
else
  # Fallback for old installs
  BASE="DSM_VirtualDSM_42962"
fi

[ -n "$URL" ] && BASE=$(basename "$URL" .pat)

if [[ ! -f "$STORAGE/$BASE.boot.img" ]] || [[ ! -f "$STORAGE/$BASE.system.img" ]]; then
  . /run/install.sh
fi

# Initialize disks
. /run/disk.sh

# Initialize network
. /run/network.sh

# Initialize agent
. /run/serial.sh

# Configure shutdown
. /run/power.sh

KVM_ACC_OPTS=""

if [ -e /dev/kvm ] && sh -c 'echo -n > /dev/kvm' &> /dev/null; then
  if [[ $(grep -e vmx -e svm /proc/cpuinfo) ]]; then
    KVM_ACC_OPTS="-machine type=q35,usb=off,accel=kvm -enable-kvm -cpu host"
  fi
fi

[ -z "${KVM_ACC_OPTS}" ] && echo "Error: KVM acceleration is disabled.." && exit 88

RAM_SIZE=$(echo "${RAM_SIZE}" | sed 's/MB/M/g;s/GB/G/g;s/TB/T/g')
EXTRA_OPTS="-nographic -object rng-random,id=rng0,filename=/dev/urandom -device virtio-rng-pci,rng=rng0 -device virtio-balloon-pci,id=balloon0,bus=pcie.0,addr=0x4"
ARGS="-m ${RAM_SIZE} -smp ${CPU_CORES} ${KVM_ACC_OPTS} ${EXTRA_OPTS} ${KVM_MON_OPTS} ${KVM_SERIAL_OPTS} ${KVM_NET_OPTS} ${KVM_DISK_OPTS}"

set -m
(
  qemu-system-x86_64 ${ARGS} & echo $! > ${_QEMU_PID}
)
set +m

pidwait -F "${_QEMU_PID}" &

set +e
wait $!
exit 0
