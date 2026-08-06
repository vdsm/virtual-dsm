#!/usr/bin/env bash
set -Eeuo pipefail

# Helper functions

info () { printf "%b%s%b" "\E[1;34m❯ \E[1;36m" "${1:-}" "\E[0m\n"; }
error () { printf "%b%s%b" "\E[1;31m❯ " "ERROR: ${1:-}" "\E[0m\n" >&2; }
warn () { printf "%b%s%b" "\E[1;31m❯ " "Warning: ${1:-}" "\E[0m\n" >&2; }

readPidFile() {

  local -n _pid="$1"
  _pid=""

  if ! _pid=$(cat -- "$2" 2>/dev/null); then
    _pid=""
    return 1
  fi

  # Reject empty, zero, or nonnumeric pidfiles so cleanup can never signal an
  # unintended process group.
  if [[ ! "$_pid" =~ ^[1-9][0-9]*$ ]]; then
    _pid=""
    return 1
  fi

  return 0
}

hasFlag() {

  # Match a whitespace-delimited token in /proc/cpuinfo
  grep -m1 '^flags[[:space:]]*:' /proc/cpuinfo | grep -Fqw -- "$1"

}

hasFeature() {

  # Match a whitespace-delimited token in /proc/cpuinfo
  grep -m1 '^Features[[:space:]]*:' /proc/cpuinfo | grep -Fqw -- "$1"

}

isAmdCpu() {

  local vendor
  vendor=$(awk -F ': *' '/^vendor_id/{print $2; exit}' /proc/cpuinfo)

  [[ "$vendor" == "AuthenticAMD" ]]
}

getPciBus() {

  local machine="${1:-${MACHINE:-q35}}"

  if [ -n "${PCI_BUS:-}" ]; then
    echo "$PCI_BUS"
    return 0
  fi

  case "${machine,,}" in
    pc|pc-i440fx*) echo "pci.0" ;;
    *)             echo "pcie.0" ;;
  esac

  return 0
}

interactive() {

  # A TTY on stdin is insufficient when /dev/tty is unavailable; require both
  # before enabling interactive console handling.
  [ -t 0 ] && : 2>/dev/null </dev/tty >/dev/tty

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

  local pid="$1"
  local timeout="${2:-10}"
  local deadline=$((SECONDS + timeout))

  while [ -n "$pid" ] && isAlive "$pid"; do
    (( SECONDS >= deadline )) && return 1
    sleep 0.2
  done

  return 0
}

waitPidFile() {

  local pid
  local file="$1"
  local timeout="${2:-10}"
  local deadline=$((SECONDS + timeout))

  readPidFile pid "$file" || return 0

  while [ -s "$file" ] && isAlive "$pid"; do
    (( SECONDS >= deadline )) && return 1
    sleep 0.2
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

  local name="$1"
  local timeout="${2:-10}"
  local deadline=$((SECONDS + timeout))

  [ -z "$name" ] && return 0

  while pgrep -f -l "$name" >/dev/null; do
    if (( SECONDS >= deadline )); then
      warn "Timed out while waiting for process: $name"
      break
    fi

    sleep 0.2
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

  local pid
  local file="$1"

  readPidFile pid "$file" || return 0

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

  # Match generated files to the owner of their bind-mounted parent directory
  # instead of assuming a fixed container or host UID.
  dir=$(dirname -- "$file")
  uid=$(stat -c '%u' "$dir") || return 1
  gid=$(stat -c '%g' "$dir") || return 1

  chown "$uid:$gid" "$file" || return 1

  return 0
}

makeDir() {

  local path="$1"
  local dir uid gid

  [ -d "$path" ] && return 0
  mkdir -p "$path" || return 1

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

app() {

  echo "Virtual DSM"
  return 0
}

finiteMemoryLimit() {

  local limit="$1"
  # cgroup v1 commonly reports this enormous sentinel for an unlimited memory
  # limit; compare as decimal strings to avoid shell integer overflow.
  local sentinel="4611686018427387904"
  local i

  [[ "$limit" =~ ^[0-9]+$ ]] || return 1

  (( ${#limit} < ${#sentinel} )) && return 0
  (( ${#limit} > ${#sentinel} )) && return 1

  for (( i=0; i<${#sentinel}; i++ )); do
    local left="${limit:i:1}"
    local right="${sentinel:i:1}"

    (( left < right )) && return 0
    (( left > right )) && return 1
  done

  return 1
}

getMemoryInfo() {

  local host_total
  local host_avail
  local limit=""
  local current=""

  host_total=$(free -b | awk '/^Mem:/ {print $2; exit}')
  host_avail=$(free -b | awk '/^Mem:/ {print $7; exit}')

  RAM_TOTAL="$host_total"
  RAM_AVAIL="$host_avail"

  if [ -r /sys/fs/cgroup/memory.max ] && [ -r /sys/fs/cgroup/memory.current ]; then
    limit=$(< /sys/fs/cgroup/memory.max)
    current=$(< /sys/fs/cgroup/memory.current)
  elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ] && [ -r /sys/fs/cgroup/memory/memory.usage_in_bytes ]; then
    limit=$(< /sys/fs/cgroup/memory/memory.limit_in_bytes)
    current=$(< /sys/fs/cgroup/memory/memory.usage_in_bytes)
  fi

  # Use the tighter of host availability and the container's remaining cgroup
  # allowance so RAM sizing cannot exceed either boundary.
  if finiteMemoryLimit "$limit" && [[ "$current" =~ ^[0-9]+$ ]]; then
    (( limit < RAM_TOTAL )) && RAM_TOTAL="$limit"

    local available=$(( limit - current ))
    (( available < 0 )) && available=0
    (( available < RAM_AVAIL )) && RAM_AVAIL="$available"
  fi

  return 0
}

showMemoryLimitHint() {

  local kernel
  kernel=$(uname -r)

  if [[ "${kernel,,}" == *microsoft-standard-wsl2* ]]; then
    info "WSL2 detected. Increase its memory limit in \"%UserProfile%\\.wslconfig\" by setting \"memory=<size>\" under \"[wsl2]\"."
    info "Then close Docker Desktop, run \"wsl --shutdown\" in PowerShell and restart Docker Desktop for the new limit to take effect."
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

writeAtomic() {

  local path="$1"
  local content="$2"
  # Use a per-process temporary file and rename so readers see either the old
  # complete value or the new complete value.
  local tmp="${path}.${BASHPID}.tmp"

  if ! printf '%s\n' "$content" > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi

  if ! mv -f -- "$tmp" "$path"; then
    rm -f -- "$tmp"
    return 1
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

  # Persistent state fills only unset variables unless force is requested,
  # preserving explicit environment overrides.
  if ! enabled "$force"; then
    [ -z "${!var:-}" ] || return 0
  fi

  value=$(readState "$name" "$prefix") || return 1
  [ -n "$value" ] || return 0

  printf -v "$var" '%s' "$value" || return 1
  return 0
}

escape () {

  local s=${1//&/\&amp;}
  s=${s//</\&lt;}
  s=${s//>/\&gt;}
  s=${s//'"'/\&quot;}

  printf -- %s "$s"

  return 0
}

escapeXML() {

  printf '%s' "$1" | sed \
    -e 's/&/\&amp;/g' \
    -e 's/</\&lt;/g' \
    -e 's/>/\&gt;/g' \
    -e 's/"/\&quot;/g' \
    -e "s/'/\&apos;/g"

  return 0
}

html() {

  local title
  local body
  local script="${2:-}"
  local footer

  title=$(escape "$APP")
  title="<title>$title</title>"
  footer=$(escape "$FOOTER1")

  body=$(escape "$1")
  if [[ "$body" == *"..." ]]; then
    body="<p class=\"loading\">${body/.../}</p>"
  fi

  local HTML
  HTML=$(<"$TEMPLATE")
  HTML="${HTML/\[1\]/$title}"
  HTML="${HTML/\[2\]/$script}"
  HTML="${HTML/\[3\]/$body}"
  HTML="${HTML/\[4\]/$footer}"
  HTML="${HTML/\[5\]/$FOOTER2}"

  # Publish both the full page and websocket fragment atomically because nginx
  # and websocketd may read them concurrently.
  writeAtomic "$PAGE" "$HTML" || return 1
  writeAtomic "$INFO" "$body" || return 1

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
  local json result

  { json=$(curl -m 5 -H "Accept: application/json" -sfk "$url"); local rc=$?; } || :
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

  # Country detection is best-effort and tries independent services in order;
  # failure leaves mirror selection at its global default.
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

  # Use a mainland mirror only for on-demand package installation, avoiding
  # slow or inaccessible Debian endpoints in that region.
  if [[ "${COUNTRY^^}" == "CN" ]]; then
    sed -i 's/deb.debian.org/mirrors.ustc.edu.cn/g' /etc/apt/sources.list.d/debian.sources
  fi

  DEBIAN_FRONTEND=noninteractive apt-get -qq update || return 1
  DEBIAN_FRONTEND=noninteractive apt-get -qq --no-install-recommends -y install "$pkg" > /dev/null || return 1

  return 0
}

return 0
