#!/usr/bin/env bash
# shellcheck disable=SC2329
set -Eeuo pipefail

: "${DHCP:="N"}"
: "${NETWORK:="Y"}"

cd /run
. utils.sh      # Load functions

info () { printf "%b%s%b" "\E[1;34m❯ \E[1;36m" "$1" "\E[0m\n" >&2; }
warn () { printf "%b%s%b" "\E[1;33m❯ " "WARNING: $1" "\E[0m\n" >&2; }
error () { printf "%b%s%b" "\E[1;31m❯ " "ERROR: $1" "\E[0m\n" >&2; }

disabled "$NETWORK" && exit 0

file="/run/shm/dsm.url"
msgs="/run/shm/msg.html"
driver="/run/shm/qemu.nic"
page="/run/shm/index.html"
address="/run/shm/qemu.ip"
shutdown="/run/shm/qemu.end"
socket="/run/shm/qemu-host-api.sock"
template="/var/www/index.html"
url="http://localhost/read?command=10"

resp_err="Guest returned an invalid response:"
curl_err="Failed to connect to guest: curl error"
jq_err="Failed to parse response from guest: jq error"

exitIfShuttingDown() {

  [ -f "$shutdown" ] && exit 1

  return 0
}

queryGuest() {

  local rc

  { json=$(curl --unix-socket "$socket" -m 20 -sk "$url"); rc=$?; } || :

  exitIfShuttingDown

  if (( rc != 0 )); then
    error "$curl_err $rc"
    return 1
  fi

  return 0
}

readJsonField() {

  local query="$1"
  local result
  local rc

  { result=$(jq -r "$query" <<< "$json"); rc=$?; } || :

  if (( rc != 0 )); then
    error "$jq_err $rc ( $json )"
    return 1
  fi

  if [[ "$result" == "null" ]]; then
    error "$resp_err $json"
    return 1
  fi

  printf '%s\n' "$result"
  return 0
}

readGuestStatus() {

  local result msg rc

  result=$(readJsonField '.status') || return 1

  if [[ "$result" != "success" ]]; then
    { msg=$(jq -r '.message // empty' <<< "$json"); rc=$?; } || :

    if (( rc != 0 )); then
      error "$jq_err $rc ( $json )"
      return 1
    fi

    error "Guest replied $result: $msg"
    return 1
  fi

  return 0
}

readGuestPort() {

  port=$(readJsonField '.data.data.dsm_setting.data.http_port') || return 1
  [ -z "$port" ] && return 1

  return 0
}

readGuestIp() {

  ip=$(readJsonField '.data.data.ip.data[] | select(.name=="eth0" and has("ip")) | .ip | select(test("^[0-9]+\\."))') || return 1
  [ -z "$ip" ] && return 1

  return 0
}

writeDsmLocation() {

  echo "$ip:$port" > "$file"

  return 0
}

pollGuestLocation() {

  while [ ! -s "$file" ]; do

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

  return 0
}

checkAddressConflict() {

  local guest_ip="${location%:*}"
  local container_ip=""

  [ -s "$address" ] && container_ip=$(<"$address")
  [ -z "$container_ip" ] && return 0
  [[ "$guest_ip" != "$container_ip" ]] && return 0

  warn "DSM is using the same IP as the container, this will cause connectivity issues."
  warn "change the container's macvlan IP or assign DSM a different address in your router."

  return 0
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
  echo "$body" > "$msgs"

  return 0
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

  return 0
}

printLoginMessage() {

  echo "" >&2
  info "-----------------------------------------------------------"
  info " You can now login to DSM at $msg"
  info "-----------------------------------------------------------"
  echo "" >&2

  return 0
}

pollGuestLocation
exitIfShuttingDown

location=$(<"$file")

if enabled "$DHCP"; then
  checkAddressConflict
  writeDhcpPage
else
  buildStaticMessage
fi

printLoginMessage

exit 0
