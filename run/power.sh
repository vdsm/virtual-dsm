#!/usr/bin/env bash
set -Eeuo pipefail

# Configure QEMU for graceful shutdown

QEMU_MONPORT=7100
QEMU_POWERDOWN_TIMEOUT=50

_QEMU_PID=/run/qemu.pid
_QEMU_SHUTDOWN_COUNTER=/run/qemu.counter

rm -f "${_QEMU_PID}"
rm -f "${_QEMU_SHUTDOWN_COUNTER}"

_trap(){
    func="$1" ; shift
    for sig ; do
        trap "$func $sig" "$sig"
    done
}

_graceful_shutdown() {

  set +e

  [ ! -f "${_QEMU_PID}" ] && return
  [ -f "${_QEMU_SHUTDOWN_COUNTER}" ] && return

  echo && info "Received $1 signal, shutting down..."
  echo 0 > "${_QEMU_SHUTDOWN_COUNTER}"

  # Don't send the powerdown signal because vDSM ignores ACPI signals
  # echo 'system_powerdown' | nc -q 1 -w 1 localhost "${QEMU_MONPORT}" > /dev/null

  # Send shutdown command to guest agent via serial port
  RESPONSE=$(curl -s -m 5 -S http://127.0.0.1:2210/read?command=6 2>&1)

  if [[ ! "${RESPONSE}" =~ "\"success\"" ]] ; then

    echo && error "Could not send shutdown command to the guest ($RESPONSE)"

    # Send a NMI interrupt which will be detected by the agent script
    if ! echo 'nmi' | nc -q 1 -w 1 localhost "${QEMU_MONPORT}" > /dev/null ; then

      kill -15 "$(cat "${_QEMU_PID}")"
      pkill -f qemu-system-x86_64 || true

    fi

  fi

  while [ "$(cat ${_QEMU_SHUTDOWN_COUNTER})" -lt "${QEMU_POWERDOWN_TIMEOUT}" ]; do

    # Increase the counter
    echo $(($(cat ${_QEMU_SHUTDOWN_COUNTER})+1)) > ${_QEMU_SHUTDOWN_COUNTER}

    # Try to connect to qemu
    if echo 'info version'| nc -q 1 -w 1 localhost "${QEMU_MONPORT}" >/dev/null 2>&1 ; then

      sleep 1
      CNT="$(cat ${_QEMU_SHUTDOWN_COUNTER})/${QEMU_POWERDOWN_TIMEOUT}"
      [[ "${DEBUG}" == [Yy1]* ]] && info "Shutting down, waiting... (${CNT})"

    fi

  done

  echo && echo "❯ Quitting..."
  echo 'quit' | nc -q 1 -w 1 localhost "${QEMU_MONPORT}" >/dev/null 2>&1 || true

  closeNetwork

  return
}

_trap _graceful_shutdown SIGTERM SIGHUP SIGINT SIGABRT SIGQUIT

MON_OPTS="-monitor telnet:localhost:${QEMU_MONPORT},server,nowait,nodelay"
