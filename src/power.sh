#!/usr/bin/env bash
set -Eeuo pipefail

# Configure QEMU for graceful shutdown

QEMU_PORT=7100
QEMU_TIMEOUT=55
QEMU_PID="/run/qemu.pid"
QEMU_COUNT="/run/qemu.count"

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
  echo && info "Received $1 signal, sending shutdown command..."

  # Don't send the powerdown signal because vDSM ignores ACPI signals
  # echo 'system_powerdown' | nc -q 1 -w 1 localhost "${QEMU_PORT}" > /dev/null

  # Send shutdown command to guest agent via serial port
  url="http://127.0.0.1:2210/read?command=6&timeout=50"
  response=$(curl -sk -m 52 -S "$url" 2>&1)

  if [[ "$response" =~ "\"success\"" ]]; then

    echo && info "Virtual DSM is now ready to shutdown..."

  else

    response="${response#*message\"\: \"}"
    echo && error "Failed to send shutdown command: ${response%%\"*}"

    kill -15 "$(cat "$QEMU_PID")"
    pkill -f qemu-system-x86_64 || true

  fi

  while [ "$(cat $QEMU_COUNT)" -lt "$QEMU_TIMEOUT" ]; do

    # Try to connect to qemu
    if echo 'info version'| nc -q 1 -w 1 localhost "$QEMU_PORT" >/dev/null 2>&1 ; then

      sleep 1

      # Increase the counter
      cnt=$(($(cat $QEMU_COUNT)+1))
      echo $cnt > "$QEMU_COUNT"

      [[ "$DEBUG" == [Yy1]* ]] && info "Shutting down, waiting... ($cnt/$QEMU_TIMEOUT)"

    else
      break 
    fi

  done

  if [ "$(cat $QEMU_COUNT)" -ge "$QEMU_TIMEOUT" ]; then
    echo && error "Shutdown timeout reached, forcefully quitting.."
  fi

  echo && echo "❯ Quitting..."
  echo 'quit' | nc -q 1 -w 1 localhost "$QEMU_PORT" >/dev/null 2>&1 || true

  { pkill -f print.sh || true; } 2>/dev/null
  { pkill -f host.bin || true; } 2>/dev/null

  closeNetwork
  sleep 1

  return
}

_trap _graceful_shutdown SIGTERM SIGHUP SIGINT SIGABRT SIGQUIT

MON_OPTS="-monitor telnet:localhost:$QEMU_PORT,server,nowait,nodelay"
