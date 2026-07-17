#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables

: "${HOST_MAC:=""}"
: "${HOST_DEBUG:=""}"
: "${HOST_MODEL:=""}"
: "${HOST_SERIAL:=""}"
: "${GUEST_SERIAL:=""}"

# Sanitize variables
HOST_MAC=$(strip "$HOST_MAC")
HOST_MODEL=$(strip "$HOST_MODEL")
HOST_SERIAL=$(strip "$HOST_SERIAL")
GUEST_SERIAL=$(strip "$GUEST_SERIAL")

validateHostMac() {
  local m

  if [ -z "$HOST_MAC" ]; then
    return 0
  fi

  HOST_MAC="${HOST_MAC//-/:}"

  if [[ ${#HOST_MAC} == 12 ]]; then
    m="$HOST_MAC"
    HOST_MAC="${m:0:2}:${m:2:2}:${m:4:2}:${m:6:2}:${m:8:2}:${m:10:2}"
  fi

  if [[ ${#HOST_MAC} != 17 ]]; then
    error "Invalid HOST_MAC address: '$HOST_MAC', should be 12 or 17 digits long!" && exit 28
  fi

  return 0
}

buildHostArguments() {

  HOST_ARGS=()
  HOST_ARGS+=("-cpu=$CPU_CORES")
  HOST_ARGS+=("-cpu_arch=$HOST_CPU")

  [ -n "$HOST_MAC" ] && HOST_ARGS+=("-mac=$HOST_MAC")
  [ -n "$HOST_MODEL" ] && HOST_ARGS+=("-model=$HOST_MODEL")
  [ -n "$HOST_SERIAL" ] && HOST_ARGS+=("-hostsn=$HOST_SERIAL")
  [ -n "$GUEST_SERIAL" ] && HOST_ARGS+=("-guestsn=$GUEST_SERIAL")

  return 0
}

startHostBinary() {

  local pid

  if enabled "$HOST_DEBUG"; then
    set -x
    ./host.bin "${HOST_ARGS[@]}" &
    { set +x; } 2>/dev/null
    pid=$!
    echo
  else
    ./host.bin "${HOST_ARGS[@]}" >/dev/null &
    pid=$!
  fi

  echo "$pid" > "$HOST_PID"

  return 0
}


waitForPort() {

  local port="$1"
  local exit_code="$2"
  local cnt=0

  while ! nc -z -w2 127.0.0.1 "$port" > /dev/null 2>&1; do
    sleep 0.1
    cnt=$((cnt + 1))
    (( cnt > 50 )) && error "Failed to connect to qemu-host.." && exit "$exit_code"
  done

  return 0
}

configureSerialPorts() {

  if enabled "${SHUTDOWN:-Y}" &&
     [ -t 1 ] &&
     [ -c /dev/tty ] &&
     : 2>/dev/null </dev/tty >/dev/tty; then

    CONSOLE_SOCKET="$QEMU_DIR/console.sock"
    MONITOR_SOCKET="$QEMU_DIR/monitor.sock"

    SERIAL_OPTS="-chardev socket,id=console0,path=$CONSOLE_SOCKET,reconnect-ms=1000 \
          -serial chardev:console0 \
          -chardev socket,id=monitor0,path=$MONITOR_SOCKET,server=on,wait=off \
          -mon chardev=monitor0,mode=readline"

  else

    SERIAL_OPTS="-serial mon:stdio"

  fi

  SERIAL_OPTS+=" \
        -device virtio-serial-pci,id=virtio-serial0,bus=pcie.0,addr=0x3 \
        -chardev socket,id=charchannel0,host=127.0.0.1,port=$CHR_PORT,reconnect=10 \
        -device virtserialport,bus=virtio-serial0.0,nr=1,chardev=charchannel0,id=channel0,name=vchannel"

  return 0

}

validateHostMac

HOST_PID="$QEMU_DIR/host.pid"

buildHostArguments
startHostBinary

sleep 0.2

waitForPort "$COM_PORT" 58
waitForPort "$CHR_PORT" 59

configureSerialPorts

return 0
