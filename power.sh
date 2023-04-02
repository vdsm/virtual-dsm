#!/usr/bin/env bash
set -eu

# Configure QEMU for graceful shutdown

QEMU_MONPORT=7100
QEMU_POWERDOWN_TIMEOUT=30

_graceful_shutdown() {

  local COUNT=0
  local QEMU_MONPORT="${QEMU_MONPORT:-7100}"
  local QEMU_POWERDOWN_TIMEOUT="${QEMU_POWERDOWN_TIMEOUT:-120}"

  set +e
  echo "Trying to shutdown gracefully.."

  # Send a NMI interrupt which will be detected by the agent
  # echo 'nmi' | nc -q 1 localhost "${QEMU_MONPORT}">/dev/null 2>&1

  echo 'system_powerdown' | nc -q 1 localhost "${QEMU_MONPORT}">/dev/null 2>&1
  echo ""

  while echo 'info version'|nc -q 1 localhost "${QEMU_MONPORT:-7100}">/dev/null 2>&1 && [ "${COUNT}" -lt "${QEMU_POWERDOWN_TIMEOUT}" ]; do
    (( COUNT++ )) || true
    echo "Shutting down, waiting... (${COUNT}/${QEMU_POWERDOWN_TIMEOUT})"
    sleep 1
  done

  if echo 'info version'|nc -q 1 localhost "${QEMU_MONPORT:-7100}">/dev/null 2>&1; then
    echo "Killing the VM.."
    echo 'quit' | nc -q 1 localhost "${QEMU_MONPORT}">/dev/null 2>&1 || true
  fi

  echo "Exiting..."
}

trap _graceful_shutdown SIGINT SIGTERM SIGHUP

KVM_MON_OPTS="-monitor telnet:localhost:${QEMU_MONPORT:-7100},server,nowait,nodelay"
