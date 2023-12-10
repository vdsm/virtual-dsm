#!/usr/bin/env bash
set -Eeuo pipefail

# Configure QEMU for graceful shutdown

QEMU_PORT=7100
QEMU_TIMEOUT=50
QEMU_PID=/run/qemu.pid
QEMU_COUNT=/run/qemu.count

rm -f "$QEMU_PID"
rm -f "$QEMU_COUNT"

_trap(){
    func="$1" ; shift
    for sig ; do
        trap "$func $sig" "$sig"
    done
}

_graceful_shutdown() {

  set +e
  local cnt response

  [ ! -f "$QEMU_PID" ] && exit 130
  [ -f "$QEMU_COUNT" ] && return

  echo 0 > "$QEMU_COUNT"
  echo && info "Received $1 signal, shutting down..."

  # Don't send the powerdown signal because vDSM ignores ACPI signals
  # echo 'system_powerdown' | nc -q 1 -w 1 localhost "${QEMU_PORT}" > /dev/null

  # Send shutdown command to guest agent via serial port
  url="http://127.0.0.1:2210/read?command=6&timeout=50"
  response=$(curl -sk -m 60 -S "$url" 2>&1)

  if [[ ! "$response" =~ "\"success\"" ]]; then

    echo && error "Failed to send shutdown command (${response#*message\"\: \"})."

    kill -15 "$(cat "$QEMU_PID")"
    pkill -f qemu-system-x86_64 || true

  fi

  while [ "$(cat $QEMU_COUNT)" -lt "$QEMU_TIMEOUT" ]; do

    # Increase the counter
    echo $(($(cat $QEMU_COUNT)+1)) > "$QEMU_COUNT"

    # Try to connect to qemu
    if echo 'info version'| nc -q 1 -w 1 localhost "$QEMU_PORT" >/dev/null 2>&1 ; then

      sleep 1

      cnt="$(cat $QEMU_COUNT)/$QEMU_TIMEOUT"
      [[ "$DEBUG" == [Yy1]* ]] && info "Shutting down, waiting... ($cnt)"

    fi

  done

  echo && echo "❯ Quitting..."
  echo 'quit' | nc -q 1 -w 1 localhost "$QEMU_PORT" >/dev/null 2>&1 || true

  pkill -f print.sh || true
  pkill -f host.bin || true

  closeNetwork
  sleep 1

  return
}

_trap _graceful_shutdown SIGTERM SIGHUP SIGINT SIGABRT SIGQUIT

MON_OPTS="-monitor telnet:localhost:$QEMU_PORT,server,nowait,nodelay"
