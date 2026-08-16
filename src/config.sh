#!/usr/bin/env bash
set -Eeuo pipefail

: "${RNG:=""}"
: "${QMP:=""}"
: "${UUID:=""}"
: "${MONITOR:=""}"

configureProcessor() {

  # Expose one thread per core in a single socket; DSM licensing and topology
  # reporting are more predictable with this fixed layout.
  CPU_OPTS="-cpu $CPU_FLAGS"
  CPU_OPTS+=" -smp $CPU_CORES,sockets=1,dies=1,cores=$CPU_CORES,threads=1"

  return 0
}

configureMemory() {

  RAM_OPTS=$(echo "-m ${RAM_SIZE^^}" | sed 's/MB/M/g;s/GB/G/g;s/TB/T/g')

  return 0
}

configureMonitor() {

  MON_OPTS=""
  [ -n "$QMP" ] && MON_OPTS+=" -qmp $QMP"
  [ -n "$MONITOR" ] && MON_OPTS+=" -monitor $MONITOR"

  MON_OPTS+=" -name $PROCESS,process=$PROCESS,debug-threads=on"
  MON_OPTS+=" -pidfile $QEMU_PID"
  MON_OPTS="${MON_OPTS# }"

  return 0
}

configureMachine() {

  local smm="off"
  enabled "${SMM:-}" && smm="on"

  # Disable firmware and chipset features that Virtual DSM does not use and
  # that can introduce extra devices or timing differences.
  MAC_OPTS="-machine type=$MACHINE,smm=$smm,usb=off"
  MAC_OPTS+=",vmport=off,dump-guest-core=off,hpet=off${KVM_OPTS}"

  UUID=$(strip "$UUID")
  [ -n "$UUID" ] && MAC_OPTS+=" -uuid $UUID"
  [ -n "${SM_BIOS:-}" ] && MAC_OPTS+=" $SM_BIOS"

  return 0
}

configureVirtioDevices() {

  local bus
  bus=$(getPciBus)

  DEV_OPTS=""

  if ! disabled "$RNG"; then
    DEV_OPTS+=" -object rng-random,id=objrng0,filename=/dev/urandom"
    DEV_OPTS+=" -device virtio-rng-pci,rng=objrng0,id=rng0,bus=$bus,addr=0x1c"
  fi

  # Keep the existing balloon device by default. When dynamic ballooning is
  # enabled, expose guest statistics and a dedicated QMP control socket.
  if ! enabled "${BALLOONING:-}"; then
    DEV_OPTS+=" -device virtio-balloon-pci,id=balloon0,bus=$bus,addr=0x4"
  else
    MON_OPTS+=" -qmp unix:${BALLOONING_SOCKET},server=on,wait=off"
    DEV_OPTS+=" -device virtio-balloon-pci,free-page-reporting=on,guest-stats-polling-interval=1,id=balloon0,bus=$bus,addr=0x4"
  fi

  DEV_OPTS="${DEV_OPTS# }"

  return 0
}

buildArguments() {

  local default="-nodefaults -boot strict=on"
  ARGS="$default $CPU_OPTS $RAM_OPTS $MAC_OPTS $DISPLAY_OPTS $MON_OPTS $SERIAL_OPTS $NET_OPTS $DISK_OPTS $BOOT_OPTS $DEV_OPTS $ARGUMENTS"

  # Collapse whitespace after optional argument groups are assembled so empty
  # features cannot leave malformed spacing in the final QEMU command.
  ARGS=$(echo "$ARGS" | sed 's/\t/ /g' | tr -s ' ')

  return 0
}

finalizeMemory

configureMemory
configureMonitor
configureMachine
configureProcessor
configureVirtioDevices

buildArguments

return 0
