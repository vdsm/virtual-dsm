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

HOST_PID="$QEMU_DIR/host.pid"
HOST_API_SOCKET="$QEMU_DIR/qemu-host-api.sock"
HOST_AGENT_SOCKET="$QEMU_DIR/qemu-host-agent.sock"

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
  HOST_ARGS+=("-api=$HOST_API_SOCKET")
  HOST_ARGS+=("-addr=$HOST_AGENT_SOCKET")

  [ -n "$HOST_MAC" ] && HOST_ARGS+=("-mac=$HOST_MAC")
  [ -n "$HOST_MODEL" ] && HOST_ARGS+=("-model=$HOST_MODEL")
  [ -n "$HOST_SERIAL" ] && HOST_ARGS+=("-hostsn=$HOST_SERIAL")
  [ -n "$GUEST_SERIAL" ] && HOST_ARGS+=("-guestsn=$GUEST_SERIAL")

  return 0
}

startHostBinary() {

  local pid

  rm -f -- "$HOST_PID" "$HOST_API_SOCKET" "$HOST_AGENT_SOCKET" || return 1

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

waitForSocket() {

  local socket="$1"
  local exit_code="$2"
  local pid cnt=0

  while [ ! -S "$socket" ]; do

    if ! read -r pid < "$HOST_PID" || ! isAlive "$pid"; then
      error "qemu-host exited unexpectedly!"
      exit "$exit_code"
    fi

    sleep 0.1
    cnt=$((cnt + 1))

    if (( cnt > 50 )); then
      error "Failed to create qemu-host socket: $socket"
      exit "$exit_code"
    fi

  done

  return 0
}

configureSerialPorts() {

  if enabled "${SHUTDOWN:-Y}" && interactive; then

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
        -chardev socket,id=charchannel0,path=$HOST_AGENT_SOCKET,reconnect-ms=1000 \
        -device virtserialport,bus=virtio-serial0.0,nr=1,chardev=charchannel0,id=channel0,name=vchannel"

  return 0
}

validateHostMac

buildHostArguments
startHostBinary

waitForSocket "$HOST_API_SOCKET" 58
waitForSocket "$HOST_AGENT_SOCKET" 59

configureSerialPorts

return 0
