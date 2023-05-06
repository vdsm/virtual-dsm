#!/usr/bin/env bash
set -u

# Docker Healthcheck

: ${DHCP:='N'}

if [[ "${DHCP}" == [Yy1]* ]]; then
  PORT=5555
  IP="127.0.0.1"
else
  PORT=5000
  IP="20.20.20.21"
fi

if ! curl -m 3 -ILfSs "http://${IP}:${PORT}/" > /dev/null; then
  echo "Failed to reach ${IP}:${PORT}"
  exit 1
fi

echo "Healthcheck OK"
exit 0
