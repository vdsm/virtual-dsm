#!/usr/bin/env bash
set -u

[ ! -f "/run/qemu.pid" ] && echo "QEMU not running yet.." && exit 0

# Retrieve IP from guest for Docker healthcheck
RESPONSE=$(curl -s -m 6 -S http://127.0.0.1:2210/read?command=10 2>&1)

if [[ ! "${RESPONSE}" =~ "\"success\"" ]] ; then
  echo "Failed to connect to guest: $RESPONSE"
  exit 1
fi

# Retrieve the HTTP port number

if [[ ! "${RESPONSE}" =~ "\"http_port\"" ]] ; then
  echo "Failed to parse response from guest: $RESPONSE"
  exit 1
fi

rest=${RESPONSE#*http_port}
rest=${rest#*:}
rest=${rest%%,*}
PORT=${rest%%\"*}

if [ -z "${PORT}" ]; then
  echo "Guest has not set a portnumber yet.."
  exit 1
fi

# Retrieve the IP address

if [[ ! "${RESPONSE}" =~ "eth0" ]] ; then
  echo "Failed to parse response from guest: $RESPONSE"
  exit 1
fi

rest=${RESPONSE#*eth0}
rest=${rest#*ip}
rest=${rest#*:}
rest=${rest#*\"}
IP=${rest%%\"*}

if [ -z "${IP}" ]; then
  echo "Guest has not received an IP yet.."
  exit 1
fi

if ! curl -m 3 -ILfSs "http://${IP}:${PORT}/" > /dev/null; then
  echo "Failed to reach ${IP}:${PORT}"
  exit 1
fi

echo "Healthcheck OK ($IP)"
exit 0
