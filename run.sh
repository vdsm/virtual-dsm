#!/usr/bin/env bash
set -eu

/run/server.sh 5000 > /dev/null &

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
    KVM_ACC_OPTS=",accel=kvm,usb=off -cpu host -enable-kvm"
  fi
fi

[ -z "${KVM_ACC_OPTS}" ] && echo "WARNING: KVM acceleration is disabled..."

pkill -f server.sh

EXTRA_OPTS="-nographic -object rng-random,id=rng0,filename=/dev/urandom -device virtio-rng-pci,rng=rng0 -device virtio-balloon-pci,id=balloon0,bus=pcie.0,addr=0x4"
ARGS="-m ${RAM_SIZE} -smp $CPU_CORES -machine type=q35${KVM_ACC_OPTS} ${EXTRA_OPTS} ${KVM_MON_OPTS} ${KVM_SERIAL_OPTS} ${KVM_NET_OPTS} ${KVM_DISK_OPTS}"

eval "qemu-system-x86_64 ${ARGS}" &

wait $!
