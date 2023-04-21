#!/usr/bin/env bash
set -eu

PORT=5000
IP="20.20.20.21"

if ! curl -m 3 -ILfSs "http://$IP:$PORT/"; then
  echo "Failed to reach $IP"
  exit 1
fi

echo "Healthcheck OK"
exit 0
