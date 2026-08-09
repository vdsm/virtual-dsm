#!/usr/bin/env bash
set -Eeuo pipefail

cd /run
. utils.sh      # Load functions

: "${DHCP:="N"}"
: "${NETWORK:="Y"}"

[ -f "/run/shm/qemu.end" ] && echo "QEMU is shutting down..." && exit 1

# Treat the startup window as healthy so container health checks do not restart
# the service before QEMU has had time to publish its PID.
[ ! -s "/run/shm/qemu.pid" ] && echo "QEMU is not running yet..." && exit 0

disabled "$NETWORK" && echo "Networking is disabled." && exit 0

file="/run/shm/dsm.url"
address="/run/shm/qemu.ip"
gateway="/run/shm/qemu.gw"

# dsm.url is written only after the guest agent reports both the DSM
# address and its configured HTTP port.
[ ! -s "$file" ] && echo "DSM has not enabled networking yet..." && exit 0

location=$(<"$file")

if ! curl -m 20 -LfSs -o /dev/null "http://$location/"; then

  # In DHCP mode the firewall must allow the container address; with port
  # forwarding it must allow the internal gateway used to reach the guest.
  if enabled "$DHCP"; then
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
