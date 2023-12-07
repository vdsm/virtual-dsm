#!/usr/bin/env bash
set -Eeuo pipefail

info () { printf "%b%s%b" "\E[1;34m❯ \E[1;36m" "$1" "\E[0m\n" >&2; }
error () { printf "%b%s%b" "\E[1;31m❯ " "ERROR: $1" "\E[0m\n" >&2; }

file="/run/dsm.url"

while [ ! -f  "$file" ]
do

  sleep 3
  [ -f "$file" ] && continue

  # Retrieve IP from guest VM

  { json=$(curl -m 30 -sk http://127.0.0.1:2210/read?command=10); rc=$?; } || :
  (( rc != 0 )) && error "Failed to connect to guest: curl error $rc" && continue

  { result=$(echo "$json" | jq -r '.status'); rc=$?; } || :
  (( rc != 0 )) && error "Failed to parse response from guest: jq error $rc ( $json )" && continue
  [[ "$result" == "null" ]] && error "Guest returned invalid response: $json" && continue

  if [[ "$result" != "success" ]] ; then
    { msg=$(echo "$json" | jq -r '.message'); rc=$?; } || :
    error "Guest replied ${result}: $msg" && continue
  fi

  { port=$(echo "$json" | jq -r '.data.data.dsm_setting.data.http_port'); rc=$?; } || :
  (( rc != 0 )) && error "Failed to parse response from guest: jq error $rc ( $json )" && continue
  [[ "$port" == "null" ]] && error "Guest returned invalid response: $json" && continue
  [ -z "${port}" ] && continue

  { ip=$(echo "$json" | jq -r '.data.data.ip.data[] | select((.name=="eth0") and has("ip")).ip'); rc=$?; } || :
  (( rc != 0 )) && error "Failed to parse response from guest: jq error $rc ( $json )" && continue
  [[ "$ip" == "null" ]] && error "Guest returned invalid response: $json" && continue
  [ -z "${ip}" ] && continue

  echo "${ip}:${port}" > $file

done

location=$(cat "$file")

if [[ "$location" != "20.20"* ]]; then

  msg="http://${location}"

else

  ip=$(ip address show dev eth0 | grep inet | awk '/inet / { print $2 }' | cut -f1 -d/)
  port="${location##*:}"

  if [[ "$ip" == "172."* ]]; then
    msg="port ${port}"
  else
    msg="http://${ip}:${port}"
  fi

fi

echo "" >&2
info "--------------------------------------------------------"
info " You can now login to DSM at ${msg}"
info "--------------------------------------------------------"
echo "" >&2
