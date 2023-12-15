#!/usr/bin/env bash
set -Eeuo pipefail

[ ! -f "/run/qemu.pid" ] && echo "QEMU not running yet.." && exit 0
[ -f "/run/qemu.count" ] && echo "QEMU is shutting down.." && exit 1

file="/run/dsm.url"
[ ! -f  "$file" ] && echo "DSM has not enabled networking yet.." && exit 1

location=$(cat "$file")

if ! curl -m 20 -ILfSs "http://$location/" > /dev/null; then
  echo "Failed to reach page at http://$location" && exit 1
fi

echo "Healthcheck OK"
exit 0
