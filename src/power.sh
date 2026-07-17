#!/usr/bin/env bash
set -Eeuo pipefail

: "${SHUTDOWN:="Y"}"        # Graceful ACPI shutdown
: "${TIMEOUT:="115"}"       # QEMU termination timeout
: "${API_TIMEOUT:="90"}"    # External API call timeout

# Configure QEMU for graceful shutdown

API_CMD=6
API_HOST="127.0.0.1:$COM_PORT"

SHUTDOWN_SKIP=0
SHUTDOWN_SIGNAL=0

QEMU_END="$QEMU_DIR/qemu.end"
CONSOLE_PID="$QEMU_DIR/console.pid"
CONSOLE_SOCKET="$QEMU_DIR/console.sock"

_trap() {

  local func="$1"; shift
  local sig

  TRAP_PID=$BASHPID

  for sig; do
    trap "$func $sig" "$sig"
  done

  return 0
}

signalCode() {

  local sig="$1"

  case "$sig" in
    SIGHUP)  echo 129 ;;
    SIGINT)  echo 130 ;;
    SIGQUIT) echo 131 ;;
    SIGABRT) echo 134 ;;
    SIGTERM) echo 143 ;;
    *)       echo 0 ;;
  esac

  return 0
}

displayReason() {

  local reason="$1"

  case "$reason" in
    129 ) echo "SIGHUP" ;;
    130 ) echo "SIGINT" ;;
    131 ) echo "SIGQUIT" ;;
    134 ) echo "SIGABRT" ;;
    143 ) echo "SIGTERM" ;;
    * )   echo "$reason" ;;
  esac

  return 0
}

readQemuPid() {

  local -n _pid="$1"

  if [ ! -s "$QEMU_PID" ] || ! read -r _pid <"$QEMU_PID"; then
    return 1
  fi

  return 0
}

forceKillQemu() {

  local reason="$1"
  local pid=""
  local display

  ! readQemuPid pid && return 0
  ! isAlive "$pid" && return 0

  display=$(displayReason "$reason")
  error "Forcefully terminating $(app), reason: $display..."
  { disown "$pid" || :; kill -9 -- "$pid" || :; } 2>/dev/null

  return 0
}

cleanupHelpers() {

  local pids=( "${HOST_PID:-}" "${WSD_PID:-}" "${CONSOLE_PID:-}" \
               "${WEB_PID:-}" "${PASST_PID:-}" "${DNSMASQ_PID:-}" )

  mKill "${pids[@]}"
  fKill "print.sh"

  closeNetwork
  return 0
}

startConsole() {

  local cnt=0
  local pid=""

  rm -f -- "$CONSOLE_SOCKET" "$CONSOLE_PID"

  if ! stty -icanon -echo isig -ixon min 1 time 0 </dev/tty; then
    error "Failed to configure serial console terminal!"
    return 1
  fi

  (
    trap '' INT QUIT
    exec nc -lU "$CONSOLE_SOCKET" </dev/tty >/dev/tty
  ) &

  pid=$!
  echo "$pid" > "$CONSOLE_PID"

  while [ ! -S "$CONSOLE_SOCKET" ]; do

    if ! isAlive "$pid"; then
      rm -f -- "$CONSOLE_PID"
      error "Serial console relay exited unexpectedly!"
      return 1
    fi

    sleep 0.02
    cnt=$((cnt + 1))

    if (( cnt > 100 )); then
      error "Failed to start serial console relay!"
      return 1
    fi

  done

  return 0
}

finish() {

  local reason=$1
  local failed=0

  if [ ! -f "$QEMU_END" ] && (( reason != 0 )); then
    failed=1
  fi

  touch "$QEMU_END"

  forceKillQemu "$reason"
  cleanupHelpers

  if ! waitPidFile "$QEMU_PID" 10; then
    warn "Timed out while waiting for $(app) to exit!"
  fi

  echo

  if (( failed == 0 )); then
    echo "❯ Shutdown completed!"
  else
    error "QEMU exited unexpectedly!"
  fi

  exit "$reason"
}

sendGuestShutdown() {

  local pid="$1"
  local response
  local url

  # Don't send the powerdown signal because vDSM ignores ACPI signals
  # nc -q 1 -w 1 -U "$QEMU_DIR/monitor.sock" &> /dev/null <<<'system_powerdown' || :

  # Send shutdown command to guest agent via serial port
  API_TIMEOUT=$(strip "$API_TIMEOUT")
  url="http://$API_HOST/read?command=$API_CMD&timeout=$API_TIMEOUT"
  response=$(curl -sk -m "$(( API_TIMEOUT+2 ))" -S "$url" 2>&1)

  if [[ "$response" =~ "\"success\"" ]]; then

    echo && info "Virtual DSM is now ready to shutdown..."

  else

    response="${response#*message\"\: \"}"
    [ -z "$response" ] && response="second signal"

    echo && error "Forcefully terminating because of: ${response%%\"*}"
    kill -15 -- "$pid" 2>/dev/null || :

  fi

  return 0
}

normalizeTimeout() {

  local term_grace=3      # seconds before loop ends to send SIGTERM
  local cleanup_grace=3   # seconds reserved after the loop for cleanup
  local elapsed
  local timeout_left
  local min

  TIMEOUT=$(strip "$TIMEOUT")
  if [[ ! "$TIMEOUT" =~ ^[0-9]+$ ]]; then
    TIMEOUT=115
  fi

  if (( TIMEOUT >= 30 )); then
    term_grace=5
    cleanup_grace=5
  elif (( TIMEOUT >= 15 )); then
    term_grace=4
    cleanup_grace=4
  fi

  elapsed=$((SECONDS - start))
  timeout_left=$((TIMEOUT - elapsed))

  min=$((term_grace + cleanup_grace + 1))
  (( timeout_left < min )) && timeout_left=$min

  wait_until=$((timeout_left - cleanup_grace))
  sigterm_at=$((wait_until - term_grace))

  return 0
}

waitForShutdown() {

  local cnt=0
  local pid="$1"
  local name="$APP"
  local slp

  while (( cnt <= wait_until && SHUTDOWN_SKIP == 0 )); do

    sleep 1 &
    slp=$!

    # Stop waiting if the process has exited
    ! isAlive "$pid" && break

    # Workaround for stale/zombie QEMU pid file
    [ ! -s "$QEMU_PID" ] && break

    if (( cnt == sigterm_at )); then
      info "${name^} is still running, sending SIGTERM... ($cnt/$wait_until)"
      kill -15 -- "$pid" 2>/dev/null || :
    elif (( cnt > 0 )) && enabled "${DEBUG:-}"; then
      info "Waiting for $name to shut down... ($cnt/$wait_until)"
    fi

    wait "$slp" || :
    (( cnt++ ))

  done

  return 0
}

graceful_shutdown() {

  local sig="$1"
  local pid=""
  local code=0

  [[ $BASHPID != "$TRAP_PID" ]] && return

  code=$(signalCode "$sig")

  if [ -f "$QEMU_END" ]; then

    if (( code == 130 && SHUTDOWN_SIGNAL == code )); then
      SHUTDOWN_SKIP=1
      echo && info "Received SIGINT again, skipping shutdown wait..."
      return
    fi

    echo && info "Received $sig signal while already shutting down..."
    return
  fi

  set +e
  start=$SECONDS
  SHUTDOWN_SIGNAL=$code

  touch "$QEMU_END"
  echo && info "Received $sig signal, sending shutdown command..."

  if ! readQemuPid pid; then
    warn "QEMU PID file ($QEMU_PID) does not exist?"
    finish "$code"
  fi

  if [ -z "$pid" ] || ! isAlive "$pid"; then
    warn "QEMU process with PID $pid does not exist?"
    finish "$code"
  fi

  sendGuestShutdown "$pid"
  normalizeTimeout
  waitForShutdown "$pid"

  finish "$code"
}

! enabled "$SHUTDOWN" && return 0
[ -n "${QEMU_TIMEOUT:-}" ] && TIMEOUT="$QEMU_TIMEOUT"

if interactive; then
  _trap graceful_shutdown SIGINT
fi

_trap graceful_shutdown SIGTERM SIGHUP SIGABRT SIGQUIT

return 0
