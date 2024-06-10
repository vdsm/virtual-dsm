#!/usr/bin/env bash
set -Eeuo pipefail

: "${NETWORK:="Y"}"

[ -f "/run/shm/qemu.end" ] && echo "QEMU is shutting down.." && exit 1
[ ! -s "/run/shm/qemu.pid" ] && echo "QEMU is not running yet.." && exit 0
[[ "$NETWORK" == [Nn]* ]] && echo "Networking is disabled.." && exit 0

file="/run/shm/dsm.url"
address="/run/shm/qemu.ip"

[ ! -s  "$file" ] && echo "DSM has not enabled networking yet.." && exit 1

location=$(<"$file")

if ! curl -m 20 -ILfSs "http://$location/" > /dev/null; then

  if [[ "$location" == "20.20"* ]]; then
    ip="20.20.20.1"
    port="${location##*:}"
    echo "Failed to reach DSM at port $port"
  else
    echo "Failed to reach DSM at http://$location"
    ip=$(<"$address")
  fi

  echo "You might need to whitelist IP $ip in the DSM firewall." && exit 1

fi

echo "Healthcheck OK"
exit 0
