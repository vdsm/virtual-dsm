#!/usr/bin/env bash
set -Eeuo pipefail

: "${RNG:=""}"
: "${QMP:=""}"
: "${UUID:=""}"
: "${MONITOR:=""}"

msg="Configuring QEMU..."
enabled "$DEBUG" && echo "$msg"

# Sanitize variables
QMP=$(strip "$QMP")
UUID=$(strip "$UUID")
MONITOR=$(strip "$MONITOR")

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

normalizeSocket() {

  local value="$1"
  local backend="${value%%,*}"

  if [[ "$backend" == *.sock && "$backend" != *:* ]]; then
    value="unix:$value"
    [[ ",$value," == *,server=* ]] || value+=",server=on"
    if [[ ",$value," != *,wait=* ]] && [[ ",$value," != *,server=off,* ]]; then
      value+=",wait=off"
    fi
  fi

  echo "$value"
}

normalizePort() {

  local value="$1"
  local protocol="$2"

  if [[ "$value" =~ ^[0-9]+$ ]]; then
    value="$protocol:0.0.0.0:$value,server=on,wait=off"
  fi

  echo "$value"
}

configureMonitor() {

  MON_OPTS=""

  if [ -n "$MONITOR" ]; then
    MONITOR=$(normalizePort "$MONITOR" "telnet")
    MONITOR=$(normalizeSocket "$MONITOR")
    MON_OPTS+=" -monitor $MONITOR"
  fi

  if [ -n "$QMP" ]; then
    QMP=$(normalizePort "$QMP" "tcp")
    QMP=$(normalizeSocket "$QMP")
    MON_OPTS+=" -qmp $QMP"
  fi

  ID_OPTS="-name ${APP// /-},process=$PROCESS"
  PID_OPTS="-pidfile $QEMU_PID"

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

  [ -n "$UUID" ] && ID_OPTS+=" -uuid $UUID"
  [ -n "${SM_BIOS:-}" ] && ID_OPTS+=" $SM_BIOS"

  return 0
}

configureDevices() {

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

  local default="-nodefaults"
  local boot="-boot strict=on"

  ARGS="$default $MAC_OPTS $CPU_OPTS $RAM_OPTS $ID_OPTS $PID_OPTS $DISPLAY_OPTS $MON_OPTS $SERIAL_OPTS $NET_OPTS $DISK_OPTS $boot $BOOT_OPTS $DEV_OPTS $ARGUMENTS"

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
configureDevices

buildArguments

return 0
