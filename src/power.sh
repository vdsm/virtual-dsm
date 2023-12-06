#!/usr/bin/env bash
set -Eeuo pipefail

# Configure QEMU for graceful shutdown

QEMU_PORT=7100
QEMU_TIMEOUT=50
QEMU_PID=/run/qemu.pid
QEMU_COUNT=/run/qemu.count

rm -f "${QEMU_PID}"
rm -f "${QEMU_COUNT}"

_trap(){
    func="$1" ; shift
    for sig ; do
        trap "$func $sig" "$sig"
    done
}

_graceful_shutdown() {

  set +e

  [ ! -f "${QEMU_PID}" ] && exit 130
  [ -f "${QEMU_COUNT}" ] && return

  echo 0 > "${QEMU_COUNT}"
  echo && info "Received $1 signal, shutting down..."

  # Don't send the powerdown signal because vDSM ignores ACPI signals
  # echo 'system_powerdown' | nc -q 1 -w 1 localhost "${QEMU_PORT}" > /dev/null

  while true; do

    # Send shutdown command to guest agent via serial port
    RESPONSE=$(curl -s -m 5 -S http://127.0.0.1:2210/read?command=6 2>&1)
    [[ "${RESPONSE}" =~ "\"success\"" ]] && break

    # Increase the counter
    echo $(($(cat ${QEMU_COUNT})+5)) > ${QEMU_COUNT}

    if [ "$(cat ${QEMU_COUNT})" -lt "${QEMU_TIMEOUT}" ]; then
      if [[ "${RESPONSE}" == "curl: (28)"* ]] ; then
        CNT="$(cat ${QEMU_COUNT})/${QEMU_TIMEOUT}"
        echo && info "Timeout while sending shutdown command (${CNT})"
        continue
      fi
    fi

    echo && error "Failed to send shutdown command ( ${RESPONSE} )."

    kill -15 "$(cat "${QEMU_PID}")"
    pkill -f qemu-system-x86_64 || true
    break

  done
  
  echo 0 > "${QEMU_COUNT}"
  
  while [ "$(cat ${QEMU_COUNT})" -lt "${QEMU_TIMEOUT}" ]; do

    # Increase the counter
    echo $(($(cat ${QEMU_COUNT})+1)) > ${QEMU_COUNT}

    # Try to connect to qemu
    if echo 'info version'| nc -q 1 -w 1 localhost "${QEMU_PORT}" >/dev/null 2>&1 ; then

      sleep 1

      CNT="$(cat ${QEMU_COUNT})/${QEMU_TIMEOUT}"
      [[ "${DEBUG}" == [Yy1]* ]] && info "Shutting down, waiting... (${CNT})"

    fi

  done

  echo && echo "❯ Quitting..."
  echo 'quit' | nc -q 1 -w 1 localhost "${QEMU_PORT}" >/dev/null 2>&1 || true

  closeNetwork

  return
}

_trap _graceful_shutdown SIGTERM SIGHUP SIGINT SIGABRT SIGQUIT

MON_OPTS="-monitor telnet:localhost:${QEMU_PORT},server,nowait,nodelay"
