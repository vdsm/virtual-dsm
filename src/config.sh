#!/usr/bin/env bash
set -Eeuo pipefail

DEF_OPTS="-nodefaults -boot strict=on"
DEV_OPTS=""

configureProcessor() {

  CPU_OPTS="-cpu $CPU_FLAGS"
  CPU_OPTS+=" -smp $CPU_CORES,sockets=1,dies=1,cores=$CPU_CORES,threads=1"

  return 0
}

configureMemory() {

  RAM_OPTS=$(echo "-m ${RAM_SIZE^^}" | sed 's/MB/M/g;s/GB/G/g;s/TB/T/g')

  return 0
}

configureMonitor() {

  MON_OPTS="-name $PROCESS,process=$PROCESS,debug-threads=on"
  MON_OPTS+=" -pidfile $QEMU_PID"

  return 0
}

configureMachine() {

  MAC_OPTS="-machine type=$MACHINE,smm=off,usb=off"
  MAC_OPTS+=",vmport=off,dump-guest-core=off,hpet=off${KVM_OPTS}"

  return 0
}

configureVirtioDevices() {

  DEV_OPTS="-device virtio-balloon-pci,id=balloon0,bus=pcie.0,addr=0x4"
  DEV_OPTS+=" -object rng-random,id=objrng0,filename=/dev/urandom"
  DEV_OPTS+=" -device virtio-rng-pci,rng=objrng0,id=rng0,bus=pcie.0,addr=0x1c"

  return 0
}

buildArguments() {

  ARGS="$DEF_OPTS $CPU_OPTS $RAM_OPTS $MAC_OPTS $DISPLAY_OPTS $MON_OPTS $SERIAL_OPTS $NET_OPTS $DISK_OPTS $DEV_OPTS $ARGUMENTS"
  ARGS=$(echo "$ARGS" | sed 's/\t/ /g' | tr -s ' ')

  return 0
}

configureMemory
configureMonitor
configureMachine
configureProcessor
configureVirtioDevices

buildArguments

return 0
