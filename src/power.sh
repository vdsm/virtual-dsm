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

finish() {

  local pid
  local reason=$1

  if [ -f "$QEMU_PID" ]; then

    pid="$(cat "$QEMU_PID")"
    echo && error "Forcefully quitting QEMU process, reason: $reason..."
    { kill -15 "$pid" || true; } 2>/dev/null

    while isAlive "$pid"; do
      sleep 1
      # Workaround for zombie pid
      [ ! -f "$QEMU_PID" ] && break
    done
  fi

  fKill "print.sh"
  fKill "host.bin"

  closeNetwork

  sleep 1
  echo && echo "❯ Shutdown completed!"

  exit "$reason"
}

_graceful_shutdown() {

  local code=$?
  local pid cnt response

  set +e

  if [ -f "$QEMU_COUNT" ]; then
    echo && info "Ignored $1 signal, already shutting down..."
    return
  fi

  echo 0 > "$QEMU_COUNT"
  echo && info "Received $1 signal, sending shutdown command..."

  if [ ! -f "$QEMU_PID" ]; then
    echo && error "QEMU PID file does not exist?"
    finish "$code" && return "$code"
  fi

  pid="$(cat "$QEMU_PID")"

  if ! isAlive "$pid"; then
    echo && error "QEMU process does not exist?"
    finish "$code" && return "$code"
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
    [ -z "$response" ] && response="second signal"
    echo && error "Forcefully quitting because of: ${response%%\"*}"
    { kill -15 "$pid" || true; } 2>/dev/null

  fi

  while [ "$(cat $QEMU_COUNT)" -lt "$QEMU_TIMEOUT" ]; do

    ! isAlive "$pid" && break

    sleep 1

    # Increase the counter
    cnt=$(($(cat $QEMU_COUNT)+1))
    echo $cnt > "$QEMU_COUNT"

    [[ "$DEBUG" == [Yy1]* ]] && info "Shutting down, waiting... ($cnt/$QEMU_TIMEOUT)"

    # Workaround for zombie pid
    [ ! -f "$QEMU_PID" ] && break

  done

  if [ "$(cat $QEMU_COUNT)" -ge "$QEMU_TIMEOUT" ]; then
    echo && error "Shutdown timeout reached!"
  fi

  finish "$code" && return "$code"
}

_trap _graceful_shutdown SIGTERM SIGHUP SIGINT SIGABRT SIGQUIT

MON_OPTS="-monitor telnet:localhost:$QEMU_PORT,server,nowait,nodelay"
