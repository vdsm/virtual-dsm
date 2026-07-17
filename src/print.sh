#!/usr/bin/env bash
# shellcheck disable=SC2329
set -Eeuo pipefail

: "${DHCP:="N"}"
: "${NETWORK:="Y"}"

cd /run
. utils.sh      # Load functions

info () { printf "%b%s%b" "\E[1;34m❯ \E[1;36m" "$1" "\E[0m\n" >&2; }
error () { printf "%b%s%b" "\E[1;31m❯ " "ERROR: $1" "\E[0m\n" >&2; }

debug() {

  local timestamp=""

  timestamp=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || true)
  printf '[print.sh %s] %s\n' "$timestamp" "$*" >&2

  return 0
}

printFileInfo() {

  local file="$1"

  if [ -e "$file" ]; then
    debug "File exists: $file"
    ls -ld "$file" >&2 || true

    if [ -f "$file" ]; then
      debug "Contents of $file:"
      sed 's/^/[print.sh file] /' "$file" >&2 || true
    fi
  else
    debug "File does not exist: $file"
  fi

  return 0
}

onError() {

  local rc="$1"
  local line="$2"
  local command="$3"

  debug "ERROR: status $rc while running: $command"
  debug "ERROR: line $line, function stack: ${FUNCNAME[*]:-unknown}"

  return "$rc"
}

onExit() {

  local rc="$1"

  debug "Exiting with status $rc"

  return 0
}

trap 'rc=$?; onError "$rc" "$LINENO" "$BASH_COMMAND"' ERR
trap 'rc=$?; onExit "$rc"' EXIT

disabled "$NETWORK" && {
  debug "Networking is disabled; exiting."
  exit 0
}

file="/run/shm/dsm.url"
msgs="/run/shm/msg.html"
driver="/run/shm/qemu.nic"
page="/run/shm/index.html"
address="/run/shm/qemu.ip"
shutdown="/run/shm/qemu.end"
template="/var/www/index.html"
url="http://127.0.0.1:2210/read?command=10"

resp_err="Guest returned an invalid response:"
curl_err="Failed to connect to guest: curl error"
jq_err="Failed to parse response from guest: jq error"

debug "Started with PID $$ and parent PID $PPID"
debug "Working directory: $PWD"
debug "DHCP=$DHCP"
debug "NETWORK=$NETWORK"
debug "HOST_DEBUG=${HOST_DEBUG:-}"
debug "DEBUG=${DEBUG:-}"
debug "TRACE=${TRACE:-}"
debug "stdout: $(readlink "/proc/$$/fd/1" 2>/dev/null || echo unknown)"
debug "stderr: $(readlink "/proc/$$/fd/2" 2>/dev/null || echo unknown)"
debug "parent stdout: $(readlink "/proc/$PPID/fd/1" 2>/dev/null || echo unknown)"
debug "parent stderr: $(readlink "/proc/$PPID/fd/2" 2>/dev/null || echo unknown)"
debug "Guest API URL: $url"

printFileInfo "$driver"
printFileInfo "$address"
printFileInfo "$shutdown"
printFileInfo "$template"

exitIfShuttingDown() {

  if [ -f "$shutdown" ]; then
    debug "Shutdown marker exists: $shutdown"
    exit 1
  fi

  return 0
}

queryGuest() {

  local rc=0

  debug "Requesting guest information from $url"

  json=""
  { json=$(curl -m 20 -sk "$url"); rc=$?; } || :

  debug "curl returned status $rc"
  debug "Response length: ${#json} bytes"

  if [ -n "$json" ]; then
    debug "Raw response: $json"

    if jq -e . >/dev/null 2>&1 <<< "$json"; then
      debug "Response contains valid JSON"
    else
      debug "Response is not valid JSON"
    fi
  else
    debug "Response was empty"
  fi

  exitIfShuttingDown

  if (( rc != 0 )); then
    error "$curl_err $rc"
    return 1
  fi

  return 0
}

readJsonField() {

  local query="$1"
  local result=""
  local quoted=""
  local rc=0

  debug "Running jq query: $query"

  { result=$(jq -r "$query" <<< "$json"); rc=$?; } || :

  printf -v quoted '%q' "$result"
  debug "jq returned status $rc"
  debug "jq result: $quoted"

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

  local result=""
  local msg=""
  local rc=0

  debug "Reading guest response status"

  result=$(readJsonField '.status') || {
    debug "Failed to read response status"
    return 1
  }

  debug "Guest response status: $result"

  if [[ "$result" != "success" ]]; then
    { msg=$(jq -r '.message // empty' <<< "$json"); rc=$?; } || :

    debug "Failed response message: $msg"
    debug "Message jq status: $rc"

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

  debug "Reading DSM HTTP port"

  port=$(readJsonField '.data.data.dsm_setting.data.http_port') || {
    debug "Failed to read DSM HTTP port"
    return 1
  }

  if [ -z "$port" ]; then
    debug "DSM HTTP port was empty"
    return 1
  fi

  debug "DSM HTTP port: $port"
  return 0
}

readGuestIp() {

  debug "Reading eth0 IPv4 address"

  ip=$(readJsonField '.data.data.ip.data[] | select(.name=="eth0" and has("ip")) | .ip | select(test("^[0-9]+\\."))') || {
    debug "Failed to read eth0 IPv4 address"
    return 1
  }

  if [ -z "$ip" ]; then
    debug "eth0 IPv4 address was empty"
    return 1
  fi

  debug "eth0 IPv4 address: $ip"
  return 0
}

writeDsmLocation() {

  local location="$ip:$port"

  debug "Writing DSM location '$location' to $file"

  if ! echo "$location" > "$file"; then
    debug "Failed to write DSM location file"
    return 1
  fi

  printFileInfo "$file"
  return 0
}

pollGuestLocation() {

  local attempt=0

  debug "Starting guest-location polling loop"

  while [ ! -s "$file" ]; do
    attempt=$((attempt + 1))

    debug "Polling attempt $attempt"
    printFileInfo "$file"

    exitIfShuttingDown

    debug "Sleeping for 3 seconds"
    sleep 3

    exitIfShuttingDown

    if [ -s "$file" ]; then
      debug "Location file appeared while sleeping"
      break
    fi

    if ! queryGuest; then
      debug "Guest API request failed; retrying"
      continue
    fi

    if ! readGuestStatus; then
      debug "Guest status was not usable; retrying"
      continue
    fi

    if ! readGuestPort; then
      debug "DSM port was not available; retrying"
      continue
    fi

    if ! readGuestIp; then
      debug "DSM IPv4 address was not available; retrying"
      continue
    fi

    if ! writeDsmLocation; then
      debug "Failed to save DSM location; retrying"
      continue
    fi

    debug "Guest location discovered successfully"
  done

  debug "Guest-location polling loop completed"
  return 0
}

writeDhcpPage() {

  local title=""
  local body=""
  local script=""
  local html=""

  msg="http://$location"
  title="<title>Virtual DSM</title>"
  body="The location of DSM is <a href='http://$location'>http://$location</a>"
  script="<script>setTimeout(function(){ window.location.assign('http://$location'); }, 3000);</script>"

  debug "DHCP mode is active"
  debug "Login message: $msg"
  debug "Reading web template from $template"

  html=$(<"$template")
  html="${html/\[1\]/$title}"
  html="${html/\[2\]/$script}"
  html="${html/\[3\]/$body}"
  html="${html/\[4\]/}"
  html="${html/\[5\]/}"

  debug "Writing redirect page to $page"
  echo "$html" > "$page"

  debug "Writing status message to $msgs"
  echo "$body" > "$msgs"

  printFileInfo "$page"
  printFileInfo "$msgs"

  return 0
}

buildStaticMessage() {

  local nic=""
  local ip=""
  local port=""

  debug "Building static-network login message"

  printFileInfo "$driver"
  printFileInfo "$address"

  nic=$(<"$driver")
  ip=$(<"$address")
  port="${location##*:}"

  debug "Network driver: $nic"
  debug "Container address: $ip"
  debug "DSM port: $port"

  if [[ "${nic,,}" != "macvlan" ]]; then
    msg="port $port"
  else
    msg="http://$ip:$port"
  fi

  debug "Login message: $msg"
  return 0
}

printLoginMessage() {

  debug "Printing welcome banner to stderr"
  debug "Banner message: You can now login to DSM at $msg"

  echo "" >&2
  info "-----------------------------------------------------------"
  info " You can now login to DSM at $msg"
  info "-----------------------------------------------------------"
  echo "" >&2

  debug "Welcome banner printed"
  return 0
}

debug "Launching pollGuestLocation"
pollGuestLocation

debug "Checking shutdown state after polling"
exitIfShuttingDown

debug "Reading final DSM location from $file"
location=$(<"$file")
debug "Final DSM location: $location"

if enabled "$DHCP"; then
  debug "Selecting DHCP page path"
  writeDhcpPage
else
  debug "Selecting static-network message path"
  buildStaticMessage
fi

debug "Calling printLoginMessage"
printLoginMessage

debug "print.sh completed successfully"
exit 0
