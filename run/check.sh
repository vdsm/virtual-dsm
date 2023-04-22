#!/usr/bin/env bash
set -u

# Docker Healthcheck

PORT=5000
FILE="/var/dsm.ip"

if [ ! -f "${FILE}" ]; then
  echo "IP not assigned"
  exit 1
fi

IP=$(cat "${FILE}")

if ! curl -m 3 -ILfSs "http://${IP}:${PORT}/" > /dev/null; then
  exit 1
fi

echo "Healthcheck OK"
exit 0
