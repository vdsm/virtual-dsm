#!/usr/bin/env bash
set -Eeuo pipefail

: "${DHCP:="N"}"
: "${NETWORK:="Y"}"

[[ "$NETWORK" == [Nn]* ]] && exit 0

info () { printf "%b%s%b" "\E[1;34m❯ \E[1;36m" "$1" "\E[0m\n" >&2; }
error () { printf "%b%s%b" "\E[1;31m❯ " "ERROR: $1" "\E[0m\n" >&2; }

file="/run/shm/dsm.url"
info="/run/shm/msg.html"
page="/run/shm/index.html"
address="/run/shm/qemu.ip"
shutdown="/run/shm/qemu.end"
template="/var/www/index.html"
url="http://127.0.0.1:2210/read?command=10"

resp_err="Guest returned an invalid response:"
curl_err="Failed to connect to guest: curl error"
jq_err="Failed to parse response from guest: jq error"

while [ ! -s  "$file" ]
do

  # Check if not shutting down
  [ -f "$shutdown" ] && exit 1

  sleep 3

  [ -f "$shutdown" ] && exit 1
  [ -s "$file" ] && break

  # Retrieve network info from guest VM
  { json=$(curl -m 20 -sk "$url"); rc=$?; } || :

  [ -f "$shutdown" ] && exit 1
  (( rc != 0 )) && error "$curl_err $rc" && continue

  { result=$(echo "$json" | jq -r '.status'); rc=$?; } || :
  (( rc != 0 )) && error "$jq_err $rc ( $json )" && continue
  [[ "$result" == "null" ]] && error "$resp_err $json" && continue

  if [[ "$result" != "success" ]] ; then
    { msg=$(echo "$json" | jq -r '.message'); rc=$?; } || :
    error "Guest replied $result: $msg" && continue
  fi

  { port=$(echo "$json" | jq -r '.data.data.dsm_setting.data.http_port'); rc=$?; } || :
  (( rc != 0 )) && error "$jq_err $rc ( $json )" && continue
  [[ "$port" == "null" ]] && error "$resp_err $json" && continue
  [ -z "$port" ] && continue

  { ip=$(echo "$json" | jq -r '.data.data.ip.data[] | select((.name=="eth0") and has("ip")).ip'); rc=$?; } || :
  (( rc != 0 )) && error "$jq_err $rc ( $json )" && continue
  [[ "$ip" == "null" ]] && error "$resp_err $json" && continue

  if [ -z "$ip" ]; then
    [[ "$DHCP" == [Yy1]* ]] && continue
    ip="20.20.20.21"
  fi

  echo "$ip:$port" > $file

done

[ -f "$shutdown" ] && exit 1

location=$(<"$file")

if [[ "$location" != "20.20"* ]]; then

  msg="http://$location"
  title="<title>Virtual DSM</title>"
  body="The location of DSM is <a href='http://$location'>http://$location</a>"
  script="<script>setTimeout(function(){ window.location.assign('http://$location'); }, 3000);</script>"

  HTML=$(<"$template")
  HTML="${HTML/\[1\]/$title}"
  HTML="${HTML/\[2\]/$script}"
  HTML="${HTML/\[3\]/$body}"
  HTML="${HTML/\[4\]/}"
  HTML="${HTML/\[5\]/}"

  echo "$HTML" > "$page"
  echo "$body" > "$info"

else

  ip=$(<"$address")
  port="${location##*:}"

  if [[ "$ip" == "172."* ]]; then
    msg="port $port"
  else
    msg="http://$ip:$port"
  fi

fi

echo "" >&2
info "-----------------------------------------------------------"
info " You can now login to DSM at $msg"
info "-----------------------------------------------------------"
echo "" >&2

exit 0
