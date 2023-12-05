#!/usr/bin/env bash
set -Eeuo pipefail

info () { echo -e "\E[1;34m❯ \E[1;36m$1\E[0m" ; }
error () { echo -e >&2 "\E[1;31m❯ ERROR: $1\E[0m" ; }
trap 'error "Status $? while: ${BASH_COMMAND} (line $LINENO/$BASH_LINENO)"' ERR

[ ! -f "/run/entry.sh" ] && error "Script must run inside Docker container!" && exit 11
[ "$(id -u)" -ne "0" ] && error "Script must be executed with root privileges." && exit 12

# Docker environment variables

: ${GPU:='N'}           # Enable GPU passthrough
: ${DEBUG:='N'}         # Enable debugging mode
: ${CONSOLE:='N'}       # Start in console mode
: ${ALLOCATE:='Y'}      # Preallocate diskspace
: ${ARGUMENTS:=''}      # Extra QEMU parameters
: ${CPU_CORES:='1'}     # Amount of CPU cores
: ${RAM_SIZE:='1G'}     # Maximum RAM amount
: ${DISK_SIZE:='16G'}   # Initial data disk size

# Helper variables

KERNEL=$(uname -r | cut -b 1)
MINOR=$(uname -r | cut -d '.' -f2)
ARCH=$(dpkg --print-architecture)
VERS=$(qemu-system-x86_64 --version | head -n 1 | cut -d '(' -f 1)

# Check folder

STORAGE="/storage"
[ ! -d "$STORAGE" ] && error "Storage folder (${STORAGE}) not found!" && exit 13

# Cleanup files

rm -f /run/dsm.url
rm -f /run/qemu.pid
rm -f /run/qemu.count

# Cleanup dirs

rm -rf /tmp/dsm
rm -rf "$STORAGE/tmp"

# Helper functions

getCountry () {

  local rc
  local json
  local result
  local url=$1
  local query=$2
  
  { json=$(curl -H "Accept: application/json" -sfk "$url"); rc=$?; } || :

  if (( rc == 0 )); then
    { result=$(echo "$json" | jq -r '"$query"' 2> /dev/null); rc=$?; } || :
    if (( rc == 0 )); then
      [[ ${#result} -ne 2 ]] && result=""
      [[ "${result^^}" == "XX" ]] && result=""
      [[ -n "$result" ]] && COUNTRY="${result^^}"
    fi
  fi
  
}

setCountry () {

  [ -z "$COUNTRY" ] && getCountry "https://api.ipapi.is" ".location.country_code"
  [ -z "$COUNTRY" ] && getCountry "https://ipinfo.io/json" ".country"
  [ -z "$COUNTRY" ] && getCountry "https://api.myip.com" ".cc"
  [ -z "$COUNTRY" ] && getCountry "https://api.ip.sb/geoip" "country_code"

}

return 0
