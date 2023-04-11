#!/usr/bin/env bash
set -eu

if /run/install.sh; then
  echo "Starting Virtual DSM..."
else
  echo "Installation failed (code $?)" && exit 81
fi

source /run/disk.sh

[ -z "${KVM_DISK_OPTS}" ] && echo "Error: Failed to setup disks..." && exit 83

source /run/network.sh

[ -z "${KVM_NET_OPTS}" ] && echo "Error: Failed to setup network..." && exit 84

source /run/serial.sh

[ -z "${KVM_SERIAL_OPTS}" ] && echo "Error: Failed to setup serial..." && exit 85

source /run/power.sh

[ -z "${KVM_MON_OPTS}" ] && echo "Error: Failed to setup monitor..." && exit 87

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
  for _SIGNAL in {1..64}; do trap "echo Caught trap ${_SIGNAL} for the QEMU process" "${_SIGNAL}"; done
  qemu-system-x86_64 ${ARGS} & echo $! > ${_QEMU_PID}
)
set +m

# Since we have to start the process with -m, we need to poll every intervall if it's still running
while [ -d "/proc/$(cat ${_QEMU_PID})"  ]; do
  sleep 1
done
