#!/usr/bin/env bash
set -eu

# Docker Healthcheck

PORT=5000
FILE="/var/dsm.ip"

if [ ! -f "${FILE}" ]; then
  echo "IP not assigned"
  exit 1
fi

IP=$(cat "${FILE}")

if ! curl -m 3 -ILfSs "http://${IP}:${PORT}/" > /dev/null; then
  echo "Failed to reach ${IP}"
  exit 1
fi

echo "Healthcheck OK"
exit 0
