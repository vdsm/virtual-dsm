#!/usr/bin/env bash
set -eu

# Configure QEMU for graceful shutdown

QEMU_MONPORT=7100
QEMU_POWERDOWN_TIMEOUT=30
_QEMU_PID=/run/qemu.pid
_QEMU_SHUTDOWN_COUNTER=/run/qemu.counter

# Allows for troubleshooting signals sent to the process
_trap(){
    func="$1" ; shift
    for sig ; do
        trap '$func $sig' "$sig"
    done
}

_graceful_shutdown(){

  local QEMU_MONPORT="${QEMU_MONPORT:-7100}"
  local QEMU_POWERDOWN_TIMEOUT="${QEMU_POWERDOWN_TIMEOUT:-120}"

  set +e
  echo "Trapped $1 signal"
  echo 0 > "${_QEMU_SHUTDOWN_COUNTER}"

  FILE="${IMG}/agent.ver"
  if [ ! -f "$FILE" ]; then
    AGENT_VERSION="1"
    echo "$AGENT_VERSION" > "$IMG"/agent.ver
  else
    AGENT_VERSION=$(cat "${FILE}")
  fi

  # Don't send the powerdown signal because Synology ignores it
  # echo 'system_powerdown' | nc -q 1 -w 1 localhost "${QEMU_MONPORT}">/dev/null

  if ((AGENT_VERSION < 2)); then
     echo "Please update the agent to allow gracefull shutdowns..."
     pkill -f qemu-system-x86_64
  else
     # Send a NMI interrupt which will be detected by the agent
     echo 'nmi' | nc -q 1 -w 1 localhost "${QEMU_MONPORT}">/dev/null
  fi

  while [ "$(cat ${_QEMU_SHUTDOWN_COUNTER})" -lt "${QEMU_POWERDOWN_TIMEOUT}" ]; do

    # Increase the counter
    echo $(($(cat ${_QEMU_SHUTDOWN_COUNTER})+1)) > ${_QEMU_SHUTDOWN_COUNTER}

    # Try to connect to qemu
    if echo 'info version'| nc -q 1 -w 1 localhost "${QEMU_MONPORT:-7100}">/dev/null; then

      sleep 1
      #echo "Shutting down, waiting... ($(cat ${_QEMU_SHUTDOWN_COUNTER})/${QEMU_POWERDOWN_TIMEOUT})"

    fi
  done

  echo "Killing VM.."
  echo 'quit' | nc -q 1 -w 1 localhost "${QEMU_MONPORT}">/dev/null || true

  return
}

_trap _graceful_shutdown SIGTERM SIGHUP SIGINT SIGABRT SIGQUIT

KVM_MON_OPTS="-monitor telnet:localhost:${QEMU_MONPORT:-7100},server,nowait,nodelay"
