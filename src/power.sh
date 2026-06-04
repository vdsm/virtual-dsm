#!/usr/bin/env bash
set -Eeuo pipefail

: "${API_TIMEOUT:="50"}"   # API Call timeout
: "${QEMU_TIMEOUT:="50"}"  # QEMU Termination timeout

# Configure QEMU for graceful shutdown

API_CMD=6
API_HOST="127.0.0.1:$COM_PORT"

QEMU_END="$QEMU_DIR/qemu.end"

if [[ "$KVM" == [Nn]* ]]; then
  API_TIMEOUT=$(( API_TIMEOUT*2 ))
  QEMU_TIMEOUT=$(( QEMU_TIMEOUT*2 ))
fi

_trap() {
  local func="$1" ; shift
  for sig ; do
    trap "$func $sig" "$sig"
  done
}

finish() {

  local pid
  local cnt=0
  local reason=$1

  touch "$QEMU_END"

  if [ -s "$QEMU_PID" ]; then

    pid=$(<"$QEMU_PID")
    echo && error "Forcefully terminating Virtual DSM, reason: $reason..."
    { kill -15 "$pid" || true; } 2>/dev/null

    while isAlive "$pid"; do

      sleep 1
      (( cnt++ ))

      # Workaround for zombie pid
      [ ! -s "$QEMU_PID" ] && break

      if [ "$cnt" -eq 5 ]; then
        echo && error "QEMU did not terminate itself, forcefully killing process..."
        { kill -9 "$pid" || true; } 2>/dev/null
      fi

    done

  fi

  fKill "print.sh"
  fKill "host.bin"

  closeNetwork

  sleep 1
  echo && echo "❯ Shutdown completed!"

  exit "$reason"
}

graceful_shutdown() {

  local sig="$1"
  local code=0
  local pid url response

  case "$sig" in
    SIGTERM) code=143 ;;
    SIGINT)  code=130 ;;
    SIGHUP)  code=129 ;;
    SIGABRT) code=134 ;;
    SIGQUIT) code=131 ;;
  esac  

  if [ -f "$QEMU_END" ]; then
    echo && info "Received $1 signal while already shutting down..."
    return
  fi

  set +e
  touch "$QEMU_END"
  echo && info "Received $1 signal, sending shutdown command..."

  if [ ! -s "$QEMU_PID" ]; then
    echo && error "QEMU PID file does not exist?"
    finish "$code" && return "$code"
  fi

  pid=$(<"$QEMU_PID")

  if ! isAlive "$pid"; then
    echo && error "QEMU process does not exist?"
    finish "$code" && return "$code"
  fi

  # Don't send the powerdown signal because vDSM ignores ACPI signals
  # echo 'system_powerdown' | nc -q 1 -w 1 localhost "$MON_PORT" > /dev/null

  # Send shutdown command to guest agent via serial port
  url="http://$API_HOST/read?command=$API_CMD&timeout=$API_TIMEOUT"
  response=$(curl -sk -m "$(( API_TIMEOUT+2 ))" -S "$url" 2>&1)

  if [[ "$response" =~ "\"success\"" ]]; then

    echo && info "Virtual DSM is now ready to shutdown..."

  else

    response="${response#*message\"\: \"}"
    [ -z "$response" ] && response="second signal"
    echo && error "Forcefully terminating because of: ${response%%\"*}"
    { kill -15 "$pid" || true; } 2>/dev/null

  fi

  local cnt=0

  while [ "$cnt" -lt "$QEMU_TIMEOUT" ]; do

    ! isAlive "$pid" && break

    sleep 1
    (( cnt++ ))

    [[ "$DEBUG" == [Yy1]* ]] && info "Shutting down, waiting... ($cnt/$QEMU_TIMEOUT)"

    # Workaround for zombie pid
    [ ! -s "$QEMU_PID" ] && break

  done

  if [ "$cnt" -ge "$QEMU_TIMEOUT" ]; then
    echo && error "Shutdown timeout reached, aborting..."
  fi

  finish "$code" && return "$code"
}

[[ "$SHUTDOWN" != [Yy1]* ]] && return 0
[ -n "${QEMU_TIMEOUT:-}" ] && TIMEOUT="$QEMU_TIMEOUT"

_trap graceful_shutdown SIGTERM SIGHUP SIGABRT SIGQUIT

return 0
