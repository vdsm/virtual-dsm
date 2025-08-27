#!/usr/bin/env bash
set -Eeuo pipefail

# Configure QEMU for graceful shutdown

API_CMD=6
API_HOST="127.0.0.1:2210"
: "${API_TIMEOUT:="50"}" # API Call timeout

QEMU_TERM=""
QEMU_PORT=7100
: "${QEMU_TIMEOUT:="50"}" # QEMU Termination timeout
QEMU_DIR="/run/shm"
QEMU_PID="$QEMU_DIR/qemu.pid"
QEMU_LOG="$QEMU_DIR/qemu.log"
QEMU_OUT="$QEMU_DIR/qemu.out"
QEMU_END="$QEMU_DIR/qemu.end"

if [[ "$KVM" == [Nn]* ]]; then
  API_TIMEOUT=$(( API_TIMEOUT*2 ))
  QEMU_TIMEOUT=$(( QEMU_TIMEOUT*2 ))
fi

touch "$QEMU_LOG"

_trap() {
  func="$1" ; shift
  for sig ; do
    trap "$func $sig" "$sig"
  done
}

finish() {

  local pid
  local reason=$1

  touch "$QEMU_END"

  if [ -s "$QEMU_PID" ]; then

    pid=$(<"$QEMU_PID")
    echo && error "Forcefully terminating QEMU process, reason: $reason..."
    { kill -15 "$pid" || true; } 2>/dev/null

    while isAlive "$pid"; do
      sleep 1
      # Workaround for zombie pid
      [ ! -s "$QEMU_PID" ] && break
    done
  fi

  fKill "print.sh"
  fKill "host.bin"

  closeNetwork

  sleep 1
  echo && echo "❯ Shutdown completed!"

  exit "$reason"
}

terminal() {

  local dev=""

  if [ -s "$QEMU_OUT" ]; then

    local msg
    msg=$(<"$QEMU_OUT")

    if [ -n "$msg" ]; then

      if [[ "${msg,,}" != "char"* ||  "$msg" != *"serial0)" ]]; then
        echo "$msg"
      fi

      dev="${msg#*/dev/p}"
      dev="/dev/p${dev%% *}"

    fi
  fi

  if [ ! -c "$dev" ]; then
    dev=$(echo 'info chardev' | nc -q 1 -w 1 localhost "$QEMU_PORT" | tr -d '\000')
    dev="${dev#*serial0}"
    dev="${dev#*pty:}"
    dev="${dev%%$'\n'*}"
    dev="${dev%%$'\r'*}"
  fi

  if [ ! -c "$dev" ]; then
    error "Device '$dev' not found!"
    finish 34 && return 34
  fi

  QEMU_TERM="$dev"
  return 0
}

_graceful_shutdown() {

  local code=$?
  local pid url response

  set +e

  if [ -f "$QEMU_END" ]; then
    echo && info "Received $1 signal while already shutting down..."
    return
  fi

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
  # echo 'system_powerdown' | nc -q 1 -w 1 localhost "${QEMU_PORT}" > /dev/null

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
    cnt=$((cnt+1))

    [[ "$DEBUG" == [Yy1]* ]] && info "Shutting down, waiting... ($cnt/$QEMU_TIMEOUT)"

    # Workaround for zombie pid
    [ ! -s "$QEMU_PID" ] && break

  done

  if [ "$cnt" -ge "$QEMU_TIMEOUT" ]; then
    echo && error "Shutdown timeout reached, aborting..."
  fi

  finish "$code" && return "$code"
}

MON_OPTS="\
        -pidfile $QEMU_PID \
        -name $PROCESS,process=$PROCESS,debug-threads=on \
        -monitor telnet:localhost:$QEMU_PORT,server,nowait,nodelay"

if [[ "$CONSOLE" != [Yy]* ]]; then

  MON_OPTS+=" -daemonize -D $QEMU_LOG"

  _trap _graceful_shutdown SIGTERM SIGHUP SIGINT SIGABRT SIGQUIT

fi

return 0
