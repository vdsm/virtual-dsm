#!/usr/bin/env bash
set -eu

/run/server.sh 5000 > /dev/null &

if /run/install.sh; then
  echo "Starting Virtual DSM..."
else
  echo "Installation failed (code $?)" && exit 81
fi

KVM_NET_OPTS=""
KVM_MON_OPTS=""
KVM_ACC_OPTS=""
KVM_DISK_OPTS=""
KVM_SERIAL_OPTS=""

source /run/disk.sh

[ -z "${KVM_DISK_OPTS}" ] && echo "Error: Failed to setup disks..." && exit 83

source /run/network.sh

[ -z "${KVM_NET_OPTS}" ] && echo "Error: Failed to setup network..." && exit 84

source /run/serial.sh

[ -z "${KVM_SERIAL_OPTS}" ] && echo "Error: Failed to setup serial..." && exit 85

source /run/power.sh

[ -z "${KVM_MON_OPTS}" ] && echo "Error: Failed to setup monitor..." && exit 87

if [ -e /dev/kvm ] && sh -c 'echo -n > /dev/kvm' &> /dev/null; then
  if [[ $(grep -e vmx -e svm /proc/cpuinfo) ]]; then
    KVM_ACC_OPTS="-enable-kvm -machine accel=kvm,usb=off -cpu host"
  fi
fi

[ -z "${KVM_ACC_OPTS}" ] && echo "WARNING: KVM acceleration is disabled..."

pkill -f server.sh

KVM_EXTRA_OPTS="-nographic -device virtio-balloon-pci,id=balloon0,bus=pci.0,addr=0x4"
ARGS="-m ${RAM_SIZE} ${KVM_ACC_OPTS} ${KVM_EXTRA_OPTS} ${KVM_MON_OPTS} ${KVM_SERIAL_OPTS} ${KVM_NET_OPTS} ${KVM_DISK_OPTS}"

eval "qemu-system-x86_64 ${ARGS}" &

wait $!
