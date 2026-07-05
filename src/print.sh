#!/usr/bin/env bash
set -Eeuo pipefail

: "${DHCP:="N"}"
: "${NETWORK:="Y"}"

[[ "$NETWORK" == [Nn]* ]] && exit 0

info () { printf "%b%s%b" "\E[1;34m❯ \E[1;36m" "$1" "\E[0m\n" >&2; }
error () { printf "%b%s%b" "\E[1;31m❯ " "ERROR: $1" "\E[0m\n" >&2; }

file="/run/shm/dsm.url"
info="/run/shm/msg.html"
driver="/run/shm/qemu.nic"
page="/run/shm/index.html"
address="/run/shm/qemu.ip"
shutdown="/run/shm/qemu.end"
template="/var/www/index.html"
url="http://127.0.0.1:2210/read?command=10"

resp_err="Guest returned an invalid response:"
curl_err="Failed to connect to guest: curl error"
jq_err="Failed to parse response from guest: jq error"

exitIfShuttingDown() {
  [ -f "$shutdown" ] && exit 1
}

queryGuest() {

  { json=$(curl -m 20 -sk "$url"); rc=$?; } || :

  exitIfShuttingDown

  if (( rc != 0 )); then
    error "$curl_err $rc"
    return 1
  fi

  return 0
}

readJsonField() {

  local query="$1"
  local -n _result="$2"

  { _result=$(echo "$json" | jq -r "$query"); rc=$?; } || :

  if (( rc != 0 )); then
    error "$jq_err $rc ( $json )"
    return 1
  fi

  if [[ "$_result" == "null" ]]; then
    error "$resp_err $json"
    return 1
  fi

  return 0
}

readGuestStatus() {

  readJsonField '.status' result || return 1

  if [[ "$result" != "success" ]] ; then
    { msg=$(echo "$json" | jq -r '.message'); rc=$?; } || :
    error "Guest replied $result: $msg"
    return 1
  fi

  return 0
}

readGuestPort() {

  readJsonField '.data.data.dsm_setting.data.http_port' port || return 1
  [ -z "$port" ] && return 1

  return 0
}

readGuestIp() {

  readJsonField '.data.data.ip.data[] | select((.name=="eth0") and has("ip")).ip' ip || return 1
  [ -z "$ip" ] && return 1

  return 0
}

writeDsmLocation() {
  echo "$ip:$port" > "$file"
}

pollGuestLocation() {

  while [ ! -s  "$file" ]
  do

    # Check if not shutting down
    exitIfShuttingDown

    sleep 3

    exitIfShuttingDown
    [ -s "$file" ] && break

    # Retrieve network info from guest VM
    queryGuest || continue
    readGuestStatus || continue
    readGuestPort || continue
    readGuestIp || continue

    writeDsmLocation

  done
}

writeDhcpPage() {

  local title body script html

  msg="http://$location"
  title="<title>Virtual DSM</title>"
  body="The location of DSM is <a href='http://$location'>http://$location</a>"
  script="<script>setTimeout(function(){ window.location.assign('http://$location'); }, 3000);</script>"

  html=$(<"$template")
  html="${html/\[1\]/$title}"
  html="${html/\[2\]/$script}"
  html="${html/\[3\]/$body}"
  html="${html/\[4\]/}"
  html="${html/\[5\]/}"

  echo "$html" > "$page"
  echo "$body" > "$info"
}

buildStaticMessage() {

  local nic ip port

  nic=$(<"$driver")
  ip=$(<"$address")
  port="${location##*:}"

  if [[ "${nic,,}" != "macvlan" ]]; then
    msg="port $port"
  else
    msg="http://$ip:$port"
  fi
}

printLoginMessage() {
  echo "" >&2
  info "-----------------------------------------------------------"
  info " You can now login to DSM at $msg"
  info "-----------------------------------------------------------"
  echo "" >&2
}

pollGuestLocation
exitIfShuttingDown

location=$(<"$file")

if [[ "$DHCP" == [Yy1]* ]]; then
  writeDhcpPage
else
  buildStaticMessage
fi

printLoginMessage

exit 0
