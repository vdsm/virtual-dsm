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
  local file="$1"
  local __var="$2"
  local pid=""

  [ -s "$file" ] || return 1
  read -r pid <"$file" || return 1
  [ -n "$pid" ] || return 1

  printf -v "$__var" '%s' "$pid"
  return 0
}

forceKillQemu() {
  local reason="$1"
  local pid=""
  local display

  if readQemuPid "$QEMU_PID" pid; then
    if isAlive "$pid"; then
      display=$(displayReason "$reason")
      error "Forcefully terminating $(app), reason: $display..."
      { disown "$pid" || :; kill -9 -- "$pid" || :; } 2>/dev/null
    fi
  fi

  return 0
}

cleanupHelpers() {
  local pids=( "${HOST_PID:-}" "${WSD_PID:-}" \
               "${WEB_PID:-}" "${PASST_PID:-}" "${DNSMASQ_PID:-}" )

  mKill "${pids[@]}"
  fKill "print.sh"
  closeNetwork

  return 0
}

finish() {

  local reason=$1

  touch "$QEMU_END"

  forceKillQemu "$reason"
  cleanupHelpers

  if ! waitPidFile "$QEMU_PID" 10; then
    warn "Timed out while waiting for $(app) to exit!"
  fi

  (( reason != 1 )) && echo && echo "❯ Shutdown completed!"
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
  local min

  term_grace=3      # seconds before loop ends to send SIGTERM
  cleanup_grace=3   # seconds reserved after the loop for cleanup

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
  local name="$1"
  local pid="$2"
  local slp

  while (( cnt <= wait_until )); do

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

    wait "$slp"
    (( cnt++ ))

  done

  return 0
}

graceful_shutdown() {

  local sig="$1"
  local pid=""
  local code=0
  local name
  local term_grace cleanup_grace
  local sigterm_at=0 wait_until=0 elapsed timeout_left
  local start

  [[ $BASHPID != "$TRAP_PID" ]] && return

  code=$(signalCode "$sig")

  if [ -f "$QEMU_END" ]; then
    echo && info "Received $1 signal while already shutting down..."
    return
  fi

  set +e
  start=$SECONDS
  touch "$QEMU_END"
  echo && info "Received $1 signal, sending shutdown command..."

  if ! readQemuPid "$QEMU_PID" pid; then
    warn "QEMU PID file ($QEMU_PID) does not exist?"
    finish "$code"
  fi

  if ! isAlive "$pid"; then
    warn "QEMU process with PID $pid does not exist?"
    finish "$code"
  fi

  sendGuestShutdown "$pid"

  name="$(app)"
  normalizeTimeout
  waitForShutdown "$name" "$pid"

  finish "$code"
}

! enabled "$SHUTDOWN" && return 0
[ -n "${QEMU_TIMEOUT:-}" ] && TIMEOUT="$QEMU_TIMEOUT"

_trap graceful_shutdown SIGTERM SIGHUP SIGABRT SIGQUIT

return 0
