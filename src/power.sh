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

finish() {

  local reason=$1 failed=0

  if [ ! -f "$QEMU_END" ] && (( reason != 0 )); then
    failed=1
  fi

  touch "$QEMU_END" || :

  forceKillQemu "$reason"
  cleanupHelpers "$HOST_PID"
  
  fKill "print.sh"
  rm -f -- "$HOST_API_SOCKET" "$HOST_AGENT_SOCKET"

  if ! waitQemuExit 10; then
    warn "Timed out while waiting for $(app) to exit!"
  fi

  stopConsole
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

  # Virtual DSM ignores ACPI powerdown, so graceful shutdown must go through
  # the qemu-host guest API exposed on the Unix socket.
  # Don't send the powerdown signal because vDSM ignores ACPI signals
  # nc -q 1 -w 1 -U "$QEMU_DIR/monitor.sock" &> /dev/null <<<'system_powerdown' || :

  # Send shutdown command to guest agent via serial port
  API_TIMEOUT=$(strip "$API_TIMEOUT")
  local url="http://localhost/read?command=$API_CMD&timeout=$API_TIMEOUT"
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

  # Divide the remaining timeout into guest wait, SIGTERM grace, and final
  # cleanup instead of allowing the API call to consume the entire budget.
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
    isAlive "$pid" || break

    # The process state is authoritative, but disappearance of both pidfiles
    # also ends the wait when a wrapper exits before process reaping completes.
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

gracefulShutdown() {

  local sig="$1"
  local pid code

  [[ $BASHPID != "$TRAP_PID" ]] && return

  code=$(signalCode "$sig")

  if (( SHUTDOWN_SIGNAL != 0 )); then

    # A second Ctrl-C is the explicit user request to skip the remaining
    # graceful-shutdown wait and proceed to forced cleanup.
    if (( code == 130 && SHUTDOWN_SIGNAL == code )); then
      SHUTDOWN_SKIP=1
      echo && info "Received SIGINT again, forcing shutdown..."
      return
    fi

    echo && info "Received $sig signal while already shutting down..."
    return
  fi

  start=$SECONDS
  SHUTDOWN_SIGNAL=$code

  # Shutdown handlers must continue through missing processes and failed cleanup
  # commands instead of being aborted by errexit.
  set +e
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

enableTrap() {

  enabled "$SHUTDOWN" || return 0

  # Keep Ctrl-C available to interactive users without installing an unnecessary
  # SIGINT handler for background/container execution.
  if interactive; then
    _trap gracefulShutdown SIGINT
  fi

  _trap gracefulShutdown SIGTERM SIGHUP SIGABRT SIGQUIT

  return 0
}

[ -n "${QEMU_TIMEOUT:-}" ] && TIMEOUT="$QEMU_TIMEOUT"

return 0
