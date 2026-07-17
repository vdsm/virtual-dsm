#!/usr/bin/env bash
set -Eeuo pipefail

# Helper functions

info () { printf "%b%s%b" "\E[1;34m❯ \E[1;36m" "${1:-}" "\E[0m\n"; }
error () { printf "%b%s%b" "\E[1;31m❯ " "ERROR: ${1:-}" "\E[0m\n" >&2; }
warn () { printf "%b%s%b" "\E[1;31m❯ " "Warning: ${1:-}" "\E[0m\n" >&2; }

interactive() {

  [ -t 1 ] &&
    [ -c /dev/tty ] &&
    : 2>/dev/null </dev/tty >/dev/tty

}

strip() {

  local value="${1:-}"

  # Remove surrounding whitespace
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"

  # Remove leading/trailing single/double quotes
  value="${value%\"}"
  value="${value#\"}"
  value="${value%\'}"
  value="${value#\'}"

  # Remove surrounding whitespace again
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"

  printf '%s' "$value"
}

enabled() {

  local value
  value=$(strip "${1:-}")

  case "${value,,}" in
    y|yes|true|1|on|enable|enabled) return 0 ;;
    *) return 1 ;;
  esac
}

disabled() {

  local value
  value=$(strip "${1:-}")

  case "${value,,}" in
    n|no|none|false|0|off|disable|disabled) return 0 ;;
    *) return 1 ;;
  esac
}

formatBytes() {

  local result

  if ! result=$(numfmt --to=iec --suffix=B "$1" | sed -r 's/([A-Z])/ \1/' | sed 's/ B/ bytes/g;'); then
    return 1
  fi

  local unit="${result//[0-9. ]}"
  result="${result//[a-zA-Z ]/}"

  if [[ "${2:-}" == "up" ]]; then
    if [[ "$result" == *"."* ]]; then
      result="${result%%.*}"
      result=$((result+1))
    fi
  else
    if [[ "${2:-}" == "down" ]]; then
      result="${result%%.*}"
    fi
  fi

  echo "$result $unit"
  return 0
}

isAlive() {

  local pid="$1"
  [ -z "$pid" ] && return 1

  if kill -0 "$pid" 2>/dev/null; then
    return 0
  fi

  return 1
}

waitPid() {

  local i=0
  local pid="$1"
  local timeout="${2:-10}"

  while [ -n "$pid" ] && isAlive "$pid"; do
    sleep 0.2
    i=$((i + 1))
    (( i >= timeout * 5 )) && return 1
  done

  return 0
}

waitPidFile() {

  local i=0
  local pid=""
  local file="$1"
  local timeout="${2:-10}"

  [ ! -s "$file" ] && return 0
  ! read -r pid <"$file" && return 0
  [ -z "$pid" ] && return 0

  while [ -s "$file" ] && isAlive "$pid"; do
    sleep 0.2
    i=$((i + 1))
    (( i >= timeout * 5 )) && return 1
  done

  rm -f -- "$file"
  return 0
}

pKill() {

  local pid="$1"
  local timeout="${2:-10}"

  { kill -15 -- "$pid" || :; } 2>/dev/null

  if ! waitPid "$pid" "$timeout"; then
    warn "Timed out while waiting for PID $pid"
  fi

  return 0
}

fWait() {

  local i=0
  local name="$1"
  local timeout="${2:-10}"

  [ -z "$name" ] && return 0

  while pgrep -f -l "$name" >/dev/null; do
    sleep 0.2
    i=$((i + 1))
    if (( i >= timeout * 5 )); then
      warn "Timed out while waiting for process: $name"
      break
    fi
  done

  return 0
}

fKill() {

  local name="$1"
  local timeout="${2:-10}"

  [ -z "$name" ] && return 0

  { pkill -f "$name" || :; } 2>/dev/null
  fWait "$name" "$timeout"

  return 0
}

sKill() {

  local pid=""
  local file="$1"

  [ ! -s "$file" ] && return 0
  ! read -r pid <"$file" && return 0
  [ -z "$pid" ] && return 0

  if isAlive "$pid"; then
    { kill -15 -- "$pid" || :; } 2>/dev/null
  fi

  return 0
}

mKill() {

  local timeout=10
  local files=("$@")

  for file in "${files[@]}"; do
    sKill "$file"
  done

  for file in "${files[@]}"; do
    if ! waitPidFile "$file" "$timeout"; then
      warn "Timed out while waiting for PID file: $file"
    fi
  done

  return 0
}

setOwner() {

  local file="$1"
  local dir uid gid

  [ ! -f "$file" ] && return 1

  dir=$(dirname -- "$file")
  uid=$(stat -c '%u' "$dir") || return 1
  gid=$(stat -c '%g' "$dir") || return 1

  ! chown "$uid:$gid" "$file" && return 1

  return 0
}

makeDir() {

  local path="$1"
  local dir uid gid

  [ -d "$path" ] && return 0
  ! mkdir -p "$path" && return 1

  dir=$(dirname -- "$path")

  if ! uid=$(stat -c '%u' "$dir") || ! gid=$(stat -c '%g' "$dir"); then
    warn "failed to determine the owner for \"$path\"."
    return 0
  fi

  if ! chown "$uid:$gid" "$path"; then
    warn "failed to set the owner for \"$path\"."
    return 0
  fi

  return 0
}

stateFile() {

  local name="$1"
  local prefix="${2:-$PROCESS}"

  [[ "$name" == */* ]] && printf '%s\n' "$name" && return 0

  printf '%s/%s.%s\n' "$STORAGE" "$prefix" "$name"
  return 0
}

writeFile() {

  local txt="$1"
  local path="$2"

  if ! printf '%s\n' "$txt" > "$path"; then
    error "Failed to write file \"$path\" !"
    return 1
  fi

  if ! setOwner "$path"; then
    warn "failed to set the owner for \"$path\"."
  fi

  return 0
}

readFile() {

  local path="$1"
  local value

  [ -s "$path" ] || return 0

  value=$(<"$path") || return 1
  value="${value//[![:print:]]/}"

  printf '%s\n' "$value"
  return 0
}

writeState() {

  local name="$1"
  local value="$2"
  local prefix="${3:-$PROCESS}"
  local path

  [ -z "$value" ] && return 0

  path=$(stateFile "$name" "$prefix") || return 1
  writeFile "$value" "$path"

  return $?
}

readState() {

  local name="$1"
  local prefix="${2:-$PROCESS}"
  local path

  path=$(stateFile "$name" "$prefix") || return 1
  readFile "$path"

  return $?
}

restoreState() {

  local var="$1"
  local name="$2"
  local force="${3:-N}"
  local prefix="${4:-$PROCESS}"
  local value

  if ! enabled "$force"; then
    [ -z "${!var:-}" ] || return 0
  fi

  value=$(readState "$name" "$prefix") || return 1
  [ -n "$value" ] || return 0

  printf -v "$var" '%s' "$value" || return 1
  return 0
}

escape () {

  local s
  s=${1//&/\&amp;}
  s=${s//</\&lt;}
  s=${s//>/\&gt;}
  s=${s//'"'/\&quot;}

  printf -- %s "$s"

  return 0
}

html() {

  local title
  local body
  local script
  local footer

  title=$(escape "$APP")
  title="<title>$title</title>"
  footer=$(escape "$FOOTER1")

  body=$(escape "$1")
  if [[ "$body" == *"..." ]]; then
    body="<p class=\"loading\">${body/.../}</p>"
  fi

  [ -n "${2:-}" ] && script="$2" || script=""

  local HTML
  HTML=$(<"$TEMPLATE")
  HTML="${HTML/\[1\]/$title}"
  HTML="${HTML/\[2\]/$script}"
  HTML="${HTML/\[3\]/$body}"
  HTML="${HTML/\[4\]/$footer}"
  HTML="${HTML/\[5\]/$FOOTER2}"

  echo "$HTML" > "$PAGE" || return 1
  echo "$body" > "$INFO" || return 1

  return 0
}

cpu() {

  local ret
  local cpu=""

  ret=$(lscpu)

  if grep -qi "model name" <<< "$ret"; then
    cpu=$(echo "$ret" | grep -m 1 -i 'model name' | cut -f 2 -d ":" | awk '{$1=$1}1' | sed 's# @.*##g' | sed s/"(R)"//g | sed 's/[^[:alnum:] ]\+/ /g' | sed 's/  */ /g')
  fi

  if [ -z "${cpu// /}" ] && grep -qi "model:" <<< "$ret"; then
    cpu=$(echo "$ret" | grep -m 1 -i 'model:' | cut -f 2 -d ":" | awk '{$1=$1}1' | sed 's# @.*##g' | sed s/"(R)"//g | sed 's/[^[:alnum:] ]\+/ /g' | sed 's/  */ /g')
  fi

  cpu="${cpu// CPU/}"
  cpu="${cpu// [0-9][0-9][0-9] Core}"
  cpu="${cpu// [0-9][0-9] Core}"
  cpu="${cpu// [0-9] Core}"
  cpu="${cpu//[0-9][0-9]th Gen }"
  cpu="${cpu//[0-9]th Gen }"
  cpu="${cpu// Processor/}"
  cpu="${cpu// Quad core/}"
  cpu="${cpu// Dual core/}"
  cpu="${cpu// Octa core/}"
  cpu="${cpu// Hexa core/}"
  cpu="${cpu// Core TM/ Core}"
  cpu="${cpu// with Radeon Graphics/}"
  cpu="${cpu// with Radeon Vega Graphics/}"
  cpu="${cpu// with Radeon Vega Mobile Gfx/}"
  cpu="${cpu// w Radeon [0-9][0-9][0-9]M Graphics/}"

  [ -z "${cpu// /}" ] && cpu="Unknown"

  echo "$cpu"
  return 0
}

getCountry() {

  local url=$1
  local query=$2
  local rc json result

  { json=$(curl -m 5 -H "Accept: application/json" -sfk "$url"); rc=$?; } || :
  (( rc != 0 )) && return 0

  { result=$(echo "$json" | jq -r "$query" 2> /dev/null); rc=$?; } || :
  (( rc != 0 )) && return 0

  [[ ${#result} -ne 2 ]] && return 0
  [[ "${result^^}" == "XX" ]] && return 0

  COUNTRY="${result^^}"

  return 0
}

setCountry() {

  [[ "${TZ,,}" == "asia/harbin" ]] && COUNTRY="CN"
  [[ "${TZ,,}" == "asia/beijing" ]] && COUNTRY="CN"
  [[ "${TZ,,}" == "asia/urumqi" ]] && COUNTRY="CN"
  [[ "${TZ,,}" == "asia/kashgar" ]] && COUNTRY="CN"
  [[ "${TZ,,}" == "asia/shanghai" ]] && COUNTRY="CN"
  [[ "${TZ,,}" == "asia/chongqing" ]] && COUNTRY="CN"

  [ -z "$COUNTRY" ] && getCountry "https://api.ipapi.is" ".location.country_code"
  [ -z "$COUNTRY" ] && getCountry "https://ifconfig.co/json" ".country_iso"
  [ -z "$COUNTRY" ] && getCountry "https://api.ip2location.io" ".country_code"
  [ -z "$COUNTRY" ] && getCountry "https://ipinfo.io/json" ".country"
  [ -z "$COUNTRY" ] && getCountry "https://api.ipquery.io/?format=json" ".location.country_code" 
  [ -z "$COUNTRY" ] && getCountry "https://api.myip.com" ".cc"

  return 0
}

addPackage() {

  local pkg=$1
  local desc=$2

  if apt-mark showinstall | grep -qx "$pkg"; then
    return 0
  fi

  MSG="Installing $desc..."
  info "$MSG" && html "$MSG"

  [ -z "$COUNTRY" ] && setCountry

  if [[ "${COUNTRY^^}" == "CN" ]]; then
    sed -i 's/deb.debian.org/mirrors.ustc.edu.cn/g' /etc/apt/sources.list.d/debian.sources
  fi

  DEBIAN_FRONTEND=noninteractive apt-get -qq update || return 1
  DEBIAN_FRONTEND=noninteractive apt-get -qq --no-install-recommends -y install "$pkg" > /dev/null || return 1

  return 0
}

return 0
