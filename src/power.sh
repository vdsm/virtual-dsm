#!/usr/bin/env bash
set -Eeuo pipefail

: "${SHUTDOWN:="Y"}"        # Graceful ACPI shutdown
: "${TIMEOUT:="115"}"       # QEMU termination timeout
: "${API_TIMEOUT:="90"}"    # External API call timeout

# Configure QEMU for graceful shutdown

API_CMD=6
API_HOST="127.0.0.1:$COM_PORT"

# Configure QEMU for graceful shutdown

QEMU_END="$QEMU_DIR/qemu.end"

_trap() {
  local func="$1"; shift
  local sig
  TRAP_PID=$BASHPID

  for sig; do
    trap "$func $sig" "$sig"
  done
}

app() {
  echo "$APP" && return 0
}

finish() {

  local i=0
  local pid=""
  local reason=$1
  local pids=( "${HOST_PID:-}" "${WSD_PID:-}" \
               "${WEB_PID:-}" "${PASST_PID:-}" "${DNSMASQ_PID:-}" )

  touch "$QEMU_END"

  if [ -s "$QEMU_PID" ]; then
    if read -r pid <"$QEMU_PID"; then
      if [ -n "$pid" ] && isAlive "$pid"; then
        local display="$reason"
        case "$reason" in
          129 ) display="SIGHUP" ;;
          130 ) display="SIGINT" ;;
          131 ) display="SIGQUIT" ;;
          134 ) display="SIGABRT" ;;
          143 ) display="SIGTERM" ;;
        esac
        error "Forcefully terminating $(app), reason: $display..."
        { disown "$pid" || :; kill -9 -- "$pid" || :; } 2>/dev/null
      fi
    fi
  fi

  mKill "${pids[@]}"
  fKill "print.sh"

  closeNetwork

  if ! waitPidFile "$QEMU_PID" 10; then
    warn "Timed out while waiting for $(app) to exit!"
  fi

  (( reason != 1 )) && echo && echo "❯ Shutdown completed!"
  exit "$reason"
}

graceful_shutdown() {

  local sig="$1"
  local pid=""
  local code=0
  local start url response elapsed

  [[ $BASHPID != "$TRAP_PID" ]] && return

  case "$sig" in
    SIGHUP)  code=129 ;;
    SIGINT)  code=130 ;;
    SIGQUIT) code=131 ;;
    SIGABRT) code=134 ;;
    SIGTERM) code=143 ;;
  esac

  if [ -f "$QEMU_END" ]; then
    echo && info "Received $1 while already shutting down..."
    return
  fi

  set +e
  start=$SECONDS
  touch "$QEMU_END"
  echo && info "Received $1 signal, sending shutdown command..."

  if [ ! -s "$QEMU_PID" ] || ! read -r pid <"$QEMU_PID"; then
    warn "QEMU PID file ($QEMU_PID) does not exist?"
    finish "$code"
  fi

  if [ -z "$pid" ] || ! isAlive "$pid"; then
    warn "QEMU process with PID $pid does not exist?"
    finish "$code"
  fi

  # Don't send the powerdown signal because vDSM ignores ACPI signals
  # nc -q 1 -w 1 -U "$QEMU_DIR/monitor.sock" &> /dev/null <<<'system_powerdown' || :

  # Send shutdown command to guest agent via serial port
  url="http://$API_HOST/read?command=$API_CMD&timeout=$API_TIMEOUT"
  response=$(curl -sk -m "$(( API_TIMEOUT+2 ))" -S "$url" 2>&1)

  if [[ "$response" =~ "\"success\"" ]]; then

    echo && info "Virtual DSM is now ready to shutdown..."

  else

    response="${response#*message\"\: \"}"
    [ -z "$response" ] && response="second signal"
    echo && error "Forcefully terminating because of: ${response%%\"*}"
    { kill -15 -- "$pid" || :; } 2>/dev/null

  fi
  
  local cnt=0 offset=3 min max name

  [[ "$TIMEOUT" =~ ^[0-9]+$ ]] || TIMEOUT=115
  [ "$TIMEOUT" -ge 15 ] && offset=4
  [ "$TIMEOUT" -ge 30 ] && offset=5
  min=$((offset + 1))
  [ "$TIMEOUT" -lt "$min" ] && TIMEOUT="$min"
  elapsed=$(( $SECONDS - $start ))
  max=$(( TIMEOUT - offset - elapsed ))
  [ "$max" -lt 1 ] && max=1
  name="$(app)"

  while [ "$cnt" -le "$max" ]; do

    sleep 1 &
    local slp=$!

    ! isAlive "$pid" && break
    # Workaround for zombie pid
    [ ! -s "$QEMU_PID" ] && break

    if [ "$cnt" -gt 0 ]; then
      [[ "$DEBUG" == [Yy1]* ]] && info "Waiting for $name to shut down... ($cnt/$max)"
    fi

    wait $slp
    (( cnt++ ))

  done

  if [ "$cnt" -ge "$max" ]; then
    echo && error "Shutdown timeout reached, aborting..."
  fi

  finish "$code"
}

[[ "$SHUTDOWN" != [Yy1]* ]] && return 0
[ -n "${QEMU_TIMEOUT:-}" ] && TIMEOUT="$QEMU_TIMEOUT"

_trap graceful_shutdown SIGTERM SIGHUP SIGABRT SIGQUIT

return 0
