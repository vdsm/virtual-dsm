#!/usr/bin/env bash
set -Eeuo pipefail

# Configure QEMU for graceful shutdown

API_CMD=6
API_TIMEOUT=50
API_HOST="127.0.0.1:2210"

QEMU_PORT=7100
QEMU_TIMEOUT=50
QEMU_PID="/run/qemu.pid"
QEMU_COUNT="/run/qemu.count"

if [[ "$KVM" == [Nn]* ]]; then
  API_TIMEOUT=$(( API_TIMEOUT*2 ))
  QEMU_TIMEOUT=$(( QEMU_TIMEOUT*2 ))
fi

rm -f "$QEMU_PID"
rm -f "$QEMU_COUNT"

_trap() {
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

  if ! isAlive "$(cat "$QEMU_PID")"; then
    echo && error "QEMU process does not exist?"
  fi

  # Don't send the powerdown signal because vDSM ignores ACPI signals
  # echo 'system_powerdown' | nc -q 1 -w 1 localhost "${QEMU_PORT}" > /dev/null

  # Send shutdown command to guest agent via serial port
  url="http://$API_HOST/read?command=$API_CMD&timeout=$API_TIMEOUT"
  response=$(curl -sk -m "$(( API_TIMEOUT+2 ))" -S "$url" 2>&1)

  if [[ "$response" =~ "\"success\"" ]]; then

    echo && info "Virtual DSM is now ready to shutdown..."

  else

    response="${response#*message\"\: \"}"
    echo && error "Forcefully quitting because of: ${response%%\"*}"
    pKill "$(cat "$QEMU_PID")"

  fi

  while [ "$(cat $QEMU_COUNT)" -lt "$QEMU_TIMEOUT" ]; do

    # Try to connect to qemu
    if ! echo 'info version'| nc -q 1 -w 1 localhost "$QEMU_PORT" >/dev/null 2>&1 ; then
      echo && echo "❯ Quitting..."
      break
    fi

    # Increase the counter
    cnt=$(($(cat $QEMU_COUNT)+1))
    echo $cnt > "$QEMU_COUNT"

    [[ "$DEBUG" == [Yy1]* ]] && info "Shutting down, waiting... ($cnt/$QEMU_TIMEOUT)"

  done

  if [ "$(cat $QEMU_COUNT)" -ge "$QEMU_TIMEOUT" ]; then
    echo && error "Shutdown timeout reached, forcefully quitting..."
  fi

  fKill "print.sh"
  fKill "host.bin"
  pKill "$(cat "$QEMU_PID")"

  closeNetwork
  sleep 0.5

  return
}

_trap _graceful_shutdown SIGTERM SIGHUP SIGINT SIGABRT SIGQUIT

MON_OPTS="-monitor telnet:localhost:$QEMU_PORT,server,nowait,nodelay"
