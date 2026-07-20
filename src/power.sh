#!/usr/bin/env bash
set -Eeuo pipefail

: "${SHUTDOWN:="Y"}"        # Graceful ACPI shutdown
: "${TIMEOUT:="105"}"       # QEMU termination timeout
: "${API_TIMEOUT:="90"}"    # External API call timeout

# Configure QEMU for graceful shutdown

API_CMD=6

SHUTDOWN_SKIP=0
SHUTDOWN_SIGNAL=0

QEMU_END="$QEMU_DIR/qemu.end"
CONSOLE_PID="$QEMU_DIR/console.pid"
CONSOLE_SOCKET="$QEMU_DIR/console.sock"
QEMU_START_PID="$QEMU_DIR/qemu.start.pid"

_trap() {

  local func="$1"; shift
  local sig

  TRAP_PID=$BASHPID

  for sig; do
    # Capture the local callback and signal while registering the trap.
    # shellcheck disable=SC2064
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
  local file

  for file in "$QEMU_START_PID" "$QEMU_PID"; do
    if [ -s "$file" ] && read -r _pid < "$file"; then
      return 0
    fi
  done

  return 1
}

qemuPidFile() {

  local -n _file="$1"

  _file="$QEMU_PID"
  [ -s "$QEMU_START_PID" ] && _file="$QEMU_START_PID"

  return 0
}

waitQemuExit() {

  local timeout="${1:-10}"
  local file=""

  qemuPidFile file
  waitPidFile "$file" "$timeout"
}

waitQemuPid() {

  local -n _pid="$1"
  local cnt=0 value=""

  while ! readQemuPid value; do
    sleep 0.02
    cnt=$((cnt + 1))
    (( cnt >= 50 )) && return 1
  done

  _pid="$value"
  return 0
}

forceKillQemu() {

  local reason="$1"
  local pid="" display

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

  rm -f -- "$HOST_API_SOCKET" "$HOST_AGENT_SOCKET"

  closeNetwork
  return 0
}

startConsole() {

  local output="${1:-/dev/tty}"
  local cnt=0 pid=""

  rm -f -- "$CONSOLE_SOCKET" "$CONSOLE_PID"

  if ! stty -icanon -echo isig -ixon min 1 time 0 </dev/tty; then
    error "Failed to configure serial console terminal!"
    return 1
  fi

  (
    trap '' INT QUIT
    exec nc -lU "$CONSOLE_SOCKET" </dev/tty >"$output"
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

stopConsole() {

  mKill "$CONSOLE_PID"

  return 0
}

startQemu() {

  rm -f -- "$QEMU_START_PID"

  (
    trap '' INT QUIT

    # shellcheck disable=SC2016
    exec setsid -f -w sh -c '
      file=$1
      shift

      "$@" &
      pid=$!
      printf "%s\n" "$pid" > "$file" || exit 1

      rc=0
      wait "$pid" 2>/dev/null || rc=$?
      exit "$rc"
    ' sh "$QEMU_START_PID" "$@"
  ) </dev/null &

  return 0
}

finish() {

  local reason=$1 failed=0

  if [ ! -f "$QEMU_END" ] && (( reason != 0 )); then
    failed=1
  fi

  touch "$QEMU_END"

  forceKillQemu "$reason"
  cleanupHelpers

  if ! waitQemuExit 10; then
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
  local response url

  # Don't send the powerdown signal because vDSM ignores ACPI signals
  # nc -q 1 -w 1 -U "$QEMU_DIR/monitor.sock" &> /dev/null <<<'system_powerdown' || :

  # Send shutdown command to guest agent via serial port
  API_TIMEOUT=$(strip "$API_TIMEOUT")
  url="http://localhost/read?command=$API_CMD&timeout=$API_TIMEOUT"
  response=$(curl --unix-socket "$HOST_API_SOCKET" -sk -m "$(( API_TIMEOUT+2 ))" -S "$url" 2>&1)

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

  TIMEOUT=$(strip "$TIMEOUT")
  if [[ ! "$TIMEOUT" =~ ^[0-9]+$ ]]; then
    TIMEOUT=105
  fi

  if (( TIMEOUT >= 30 )); then
    term_grace=5
    cleanup_grace=5
  elif (( TIMEOUT >= 15 )); then
    term_grace=4
    cleanup_grace=4
  fi

  local elapsed=$((SECONDS - start))
  local timeout_left=$((TIMEOUT - elapsed))

  local min=$((term_grace + cleanup_grace + 1))
  (( timeout_left < min )) && timeout_left=$min

  wait_until=$((timeout_left - cleanup_grace))
  sigterm_at=$((wait_until - term_grace))

  return 0
}

waitForShutdown() {

  local cnt=0
  local pid="$1"
  local name="$APP"

  while (( cnt <= wait_until && SHUTDOWN_SKIP == 0 )); do

    sleep 1 &
    local slp=$!

    # Stop waiting if the process has exited
    ! isAlive "$pid" && break

    # Workaround for stale/zombie QEMU pid file
    [ ! -s "$QEMU_START_PID" ] && [ ! -s "$QEMU_PID" ] && break

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
  local pid="" code=0

  [[ $BASHPID != "$TRAP_PID" ]] && return

  code=$(signalCode "$sig")

  if [ -f "$QEMU_END" ]; then

    if (( code == 130 && SHUTDOWN_SIGNAL == code )); then
      SHUTDOWN_SKIP=1
      echo && info "Received SIGINT again, forcing shutdown..."
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
    if ! interactive || ! waitQemuPid pid; then
      warn "QEMU PID file does not exist?"
      finish "$code"
    fi
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
