#!/usr/bin/env bash
set -Eeuo pipefail

[ -f "/run/qemu.end" ] && echo "QEMU is shutting down.." && exit 1
[ ! -f "/run/qemu.pid" ] && echo "QEMU is not running yet.." && exit 0

file="/run/dsm.url"
address="/run/qemu.ip"

[ ! -f  "$file" ] && echo "DSM has not enabled networking yet.." && exit 1

location=$(cat "$file")

if ! curl -m 20 -ILfSs "http://$location/" > /dev/null; then

  if [[ "$location" == "20.20"* ]]; then
    ip="20.20.20.1"
    port="${location##*:}"
    echo "Failed to reach DSM at port $port"
  else
    echo "Failed to reach DSM at http://$location"
    ip="$(cat "$address")"
  fi

  echo "You might need to whitelist IP $ip in the DSM firewall." && exit 1

fi

echo "Healthcheck OK"
exit 0
