#!/usr/bin/env bash
set -Eeuo pipefail

[ ! -f "/run/qemu.pid" ] && echo "QEMU not running yet.." && exit 0
[ -f "/run/qemu.count" ] && echo "QEMU is shutting down.." && exit 1

file="/run/dsm.url"

if [ ! -f  "$file" ]; then

  # Retrieve IP from guest VM for Docker healthcheck

  { json=$(curl -m 30 -sk http://127.0.0.1:2210/read?command=10); rc=$?; } || :
  (( rc != 0 )) && echo "Failed to connect to guest: curl error $rc" && exit 1

  { result=$(echo "$json" | jq -r '.status'); rc=$?; } || :
  (( rc != 0 )) && echo "Failed to parse response from guest: jq error $rc ( $json )" && exit 1
  [[ "$result" == "null" ]] && echo "Guest returned invalid response: $json" && exit 1

  if [[ "$result" != "success" ]] ; then
    { msg=$(echo "$json" | jq -r '.message'); rc=$?; } || :
    echo "Guest replied $result: $msg" && exit 1
  fi

  { port=$(echo "$json" | jq -r '.data.data.dsm_setting.data.http_port'); rc=$?; } || :
  (( rc != 0 )) && echo "Failed to parse response from guest: jq error $rc ( $json )" && exit 1
  [[ "$port" == "null" ]] && echo "Guest has not set a portnumber yet.." && exit 1
  [ -z "$port" ] && echo "Guest has not set a portnumber yet.." && exit 1

  { ip=$(echo "$json" | jq -r '.data.data.ip.data[] | select((.name=="eth0") and has("ip")).ip'); rc=$?; } || :
  (( rc != 0 )) && echo "Failed to parse response from guest: jq error $rc ( $json )" && exit 1
  [[ "$ip" == "null" ]] && echo "Guest returned invalid response: $json" && exit 1
  [ -z "$ip" ] && echo "Guest has not received an IP yet.." && exit 1

  echo "$ip:$port" > $file

fi

location=$(cat "$file")

if ! curl -m 20 -ILfSs "http://$location/" > /dev/null; then
  echo "Failed to reach http://$location"
  exit 1
fi

echo "Healthcheck OK"
exit 0
