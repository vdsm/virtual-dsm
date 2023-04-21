#!/usr/bin/env bash
set -eu

# Docker Healthcheck

PORT=5000
IP="20.20.20.21"

FILE="/var/dsm.ip"
[ -f "$FILE" ] && IP=$(cat "${FILE}")

if ! curl -m 3 -ILfSs "http://$IP:$PORT/"; then
  echo "Failed to reach $IP"
  exit 1
fi

echo "Healthcheck OK for $IP"
exit 0
