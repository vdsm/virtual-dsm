#!/usr/bin/env bash
set -Eeuo pipefail

: ${VM_NET_DEV:='eth0'}

[ -f "/run/qemu.count" ] && echo "QEMU is shutting down.." && exit 1
[ ! -f "/run/qemu.pid" ] && echo "QEMU not running yet.." && exit 0

file="/run/dsm.url"
[ ! -f  "$file" ] && echo "DSM has not enabled networking yet.." && exit 1

location=$(cat "$file")

if ! curl -m 20 -ILfSs "http://$location/" > /dev/null; then

  if [[ "$location" == "20.20"* ]]; then
    ip="20.20.20.1"
    port="${location##*:}"
    echo "Failed to reach DSM at port $port"
  else
    echo "Failed to reach DSM at http://$location"
    ip=$(ip address show dev "$VM_NET_DEV" | grep inet | awk '/inet / { print $2 }' | cut -f1 -d/)
  fi

  echo "You might need to whitelist IP $ip in the DSM firewall." && exit 1

fi

echo "Healthcheck OK"
exit 0
