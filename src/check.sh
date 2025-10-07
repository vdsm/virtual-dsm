#!/usr/bin/env bash
set -Eeuo pipefail

: "${DHCP:="N"}"
: "${NETWORK:="Y"}"

[ -f "/run/shm/qemu.end" ] && echo "QEMU is shutting down.." && exit 1
[ ! -s "/run/shm/qemu.pid" ] && echo "QEMU is not running yet.." && exit 0
[[ "$NETWORK" == [Nn]* ]] && echo "Networking is disabled.." && exit 0

file="/run/shm/dsm.url"
address="/run/shm/qemu.ip"
gateway="/run/shm/qemu.gw"

[ ! -s  "$file" ] && echo "DSM has not enabled networking yet.." && exit 1

location=$(<"$file")

if ! curl -m 20 -ILfSs "http://$location/" > /dev/null; then

  if [[ "$DHCP" == [Yy1]* ]]; then
    ip=$(<"$address")
    echo "Failed to reach DSM at http://$location"
  else
    ip=$(<"$gateway")
    port="${location##*:}"
    echo "Failed to reach DSM at port $port"
  fi

  echo "You might need to whitelist IP $ip in the DSM firewall." && exit 1

fi

echo "Healthcheck OK"
exit 0
