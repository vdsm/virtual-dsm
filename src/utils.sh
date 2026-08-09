#!/usr/bin/env bash
set -Eeuo pipefail

# Helper functions

info () { printf "%b%s%b" "\E[1;34m❯ \E[1;36m" "${1:-}" "\E[0m\n"; }
error () { printf "%b%s%b" "\E[1;31m❯ " "ERROR: ${1:-}" "\E[0m\n" >&2; }
warn () { printf "%b%s%b" "\E[1;31m❯ " "Warning: ${1:-}" "\E[0m\n" >&2; }

app() {

  local name="$APP"

  if [[ "$name" == "QEMU" ]]; then
    name="the virtual machine"
  fi

  echo "$name"
  return 0
}

_trap() {

  local func="$1"; shift
  local sig

  TRAP_PID=$BASHPID

  for sig; do
    # Capture the local callback and signal while registering the trap.
    # shellcheck disable=SC2064
    trap "$func $sig" "$sig"
  done

  return 0
}

signalCode() {

  local sig="$1"

  case "$sig" in
    SIGHUP)  echo 129 ;;
    SIGINT)  echo 130 ;;
    SIGQUIT) echo 131 ;;
    SIGABRT) echo 134 ;;
    SIGTERM) echo 143 ;;
    *)       echo 0 ;;
  esac

  return 0
}

displayReason() {

  local reason="$1"

  case "$reason" in
    129 ) echo "SIGHUP" ;;
    130 ) echo "SIGINT" ;;
    131 ) echo "SIGQUIT" ;;
    134 ) echo "SIGABRT" ;;
    143 ) echo "SIGTERM" ;;
    * )   echo "$reason" ;;
  esac

  return 0
}

readPidFile() {

  local -n _pid="$1"
  _pid=""

  if ! _pid=$(cat -- "$2" 2>/dev/null); then
    _pid=""
    return 1
  fi

  if [[ ! "$_pid" =~ ^[1-9][0-9]*$ ]]; then
    _pid=""
    return 1
  fi

  return 0
}

readQemuPid() {

  # Prefer the supervisor-created PID during startup; fall back to QEMU's own
  # pidfile once it becomes available.
  readPidFile "$1" "$QEMU_START_PID" && return 0
  readPidFile "$1" "$QEMU_PID"
}

qemuPidFile() {

  local -n _file="$1"

  _file="$QEMU_PID"
  [ -s "$QEMU_START_PID" ] && _file="$QEMU_START_PID"

  return 0
}

terminateQemu() {

  local file

  qemuPidFile file
  sKill "$file"

  return 0
}

waitQemuExit() {

  local timeout="${1:-10}"
  local file

  qemuPidFile file
  waitPidFile "$file" "$timeout"
}

waitQemuPid() {

  local cnt=0

  while ! readQemuPid "$1"; do
    sleep 0.02
    cnt=$((cnt + 1))
    (( cnt >= 50 )) && return 1
  done

  return 0
}

forceKillQemu() {

  local reason="$1"
  local pid display

  readQemuPid pid || return 0
  isAlive "$pid" || return 0

  display=$(displayReason "$reason")
  error "Forcefully terminating $(app), reason: $display..."
  { disown "$pid" || :; kill -9 -- "$pid" || :; } 2>/dev/null

  return 0
}

cleanupHelpers() {

  local var
  local pids=()

  for var in "${HELPER_PIDS[@]}"; do
    local value="${!var:-}"
    [ -n "$value" ] && pids+=( "$value" )
  done

  pids+=( "$@" )
  mKill "${pids[@]}"

  closeNetwork
  return 0
}

startConsole() {

  local output="${1:-/dev/tty}"
  local cnt=0

  rm -f -- "$CONSOLE_SOCKET" "$CONSOLE_PID"

  if ! stty -icanon -echo isig -ixon min 1 time 0 </dev/tty; then
    error "Failed to configure serial console terminal!"
    return 1
  fi

  (
    trap '' INT QUIT
    exec nc -lU "$CONSOLE_SOCKET" </dev/tty >"$output"
  ) &

  local pid="$!"
  echo "$pid" > "$CONSOLE_PID"

  while [ ! -S "$CONSOLE_SOCKET" ]; do

    if ! isAlive "$pid"; then
      rm -f -- "$CONSOLE_PID"
      error "Serial console relay exited unexpectedly!"
      return 1
    fi

    sleep 0.02
    cnt=$((cnt + 1))

    if (( cnt > 100 )); then
      error "Failed to start serial console relay!"
      return 1
    fi

  done

  return 0
}

stopConsole() {

  mKill "$CONSOLE_PID"

  return 0
}

startQemu() {

  rm -f -- "$QEMU_START_PID"

  (
    trap '' INT QUIT

    # setsid detaches QEMU from the interactive process group. The wrapper records
    # the actual QEMU PID and propagates its exit status to the parent shell.
    # shellcheck disable=SC2016
    exec setsid -f -w sh -c '
      file=$1
      shift

      "$@" &
      pid=$!
      printf "%s\n" "$pid" > "$file" || exit 1

      rc=0
      wait "$pid" 2>/dev/null || rc=$?
      exit "$rc"
    ' sh "$QEMU_START_PID" "$@"
  ) </dev/null &

  return 0
}

normalizeTimeout() {

  local default_timeout="${1:-13}"
  local term_grace=3      # seconds before loop ends to send SIGTERM
  local cleanup_grace=3   # seconds reserved after the loop for cleanup

  TIMEOUT=$(strip "$TIMEOUT")
  if [[ ! "$TIMEOUT" =~ ^[0-9]+$ ]]; then
    TIMEOUT="$default_timeout"
  fi

  if (( TIMEOUT >= 30 )); then
    term_grace=5
    cleanup_grace=5
  elif (( TIMEOUT >= 15 )); then
    term_grace=4
    cleanup_grace=4
  fi

  # Reserve separate portions of TIMEOUT for SIGTERM escalation and final helper
  # cleanup instead of spending the entire budget on ACPI waiting.
  local min=$((term_grace + cleanup_grace + 1))
  (( TIMEOUT < min )) && (( TIMEOUT = min ))

  wait_until=$((TIMEOUT - cleanup_grace))
  sigterm_at=$((wait_until - term_grace))

  return 0
}

sendAcpiShutdown() {

  [ ! -S "$ACPI_SOCKET" ] && return 0

  # Send ACPI shutdown signal
  nc -q 1 -w 1 -U "$ACPI_SOCKET" &> /dev/null <<<'system_powerdown' || :

  return 0
}

waitForShutdown() {

  local pid="$1"
  local name="$APP"
  local cnt=0

  if [[ "$name" == "QEMU" ]]; then
    name="the virtual machine"
  fi

  while (( cnt <= wait_until && SHUTDOWN_SKIP == 0 )); do

    sleep 1 &
    local slp="$!"

    # Stop waiting if the process has exited
    isAlive "$pid" || break

    # Workaround for stale/zombie QEMU pid file
    [ ! -s "$QEMU_START_PID" ] && [ ! -s "$QEMU_PID" ] && break

    if (( cnt == sigterm_at )); then
      info "${name^} is still running, sending SIGTERM... ($cnt/$wait_until)"
      kill -15 -- "$pid" 2>/dev/null || :
    elif (( cnt > 0 )); then
      info "Waiting for $name to shut down... ($cnt/$wait_until)"
    fi

    sendAcpiShutdown

    wait "$slp" || :
    (( cnt++ ))

  done

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

isQ35() {

  local machine="${1:-${MACHINE:-q35}}"

  case "${machine,,}" in
    q35|pc-q35*) return 0 ;;
  esac

  return 1
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

  # Reopening /dev/tty verifies that the terminal is genuinely usable, not just
  # that stdin happens to report itself as a TTY.
  [ -t 0 ] && : 2>/dev/null </dev/tty >/dev/tty

}

containerID() {

  local id
  id=$(hostname -s 2>/dev/null || true)

  if [ -z "$id" ] && [ -s /etc/machine-id ]; then
    id=$(< /etc/machine-id)
  fi

  if [ -z "$id" ] && [ -r /proc/sys/kernel/random/boot_id ]; then
    id=$(< /proc/sys/kernel/random/boot_id)
  fi

  [ -z "$id" ] && id="unknown"

  echo "$id"
  return 0
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

setOwner() {

  local file="$1"
  local dir uid gid

  [ ! -f "$file" ] && return 1

  dir=$(dirname -- "$file")
  # Generated files inherit ownership from their containing bind mount so they
  # remain manageable by the host user.
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

stateFile() {

  local name="$1"
  local prefix="${2:-$PROCESS}"

  # A name containing a slash is already an explicit path; simple names are
  # namespaced by process under the storage directory.
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

  # Persisted state fills only unset variables by default, preserving explicit
  # environment choices unless the caller requests a forced restore.
  if ! enabled "$force"; then
    [ -z "${!var:-}" ] || return 0
  fi

  value=$(readState "$name" "$prefix") || return 1
  [ -n "$value" ] || return 0

  printf -v "$var" '%s' "$value" || return 1
  return 0
}

mergeState() {

  local var="$1"
  local name="$2"
  local separator="${3:-,}"
  local prefix="${4:-$PROCESS}"
  local current="${!var:-}"
  
  local value
  value=$(readState "$name" "$prefix") || return 1

  [ -n "$value" ] || return 0

  # Put current configuration first so user-provided flags precede and therefore
  # take priority over supplemental values restored from state.
  if [ -n "$current" ]; then
    value="$current$separator$value"
  fi

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

  # Publish both the complete page and the live message atomically because the
  # web server and websocket helper may read them concurrently.
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

baseDir() {

  local path="${1%/}"

  [[ -z "$path" || "$path" == "/" ]] && {
    echo "/"
    return 0
  }

  path="${path#/}"
  path="${path%%/*}"

  echo "/$path"
  return 0
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

getDisk() {

  local path
  local format="${DISK_FMT:-}"
  local name="${DISK_NAME:-data}"

  enabled "${DISK_DISABLE:-}" && return 1

  # Disk discovery prefers an explicitly configured block device, then legacy
  # device paths, and finally managed image files.
  if [ -n "${DEVICE:-}" ]; then
    [ -b "$DEVICE" ] || return 1
    printf '%s\n' "$DEVICE"
    return 0
  fi

  for path in "/disk" "/disk1" "/dev/disk1"; do
    if [ -b "$path" ]; then
      printf '%s\n' "$path"
      return 0
    fi
  done

  case "${format,,}" in
    raw)
      path="$STORAGE/$name.img"
      if [ ! -f "$path" ] || [ ! -s "$path" ]; then
        path="$STORAGE/$name.qcow2"
      fi ;;
    *)
      path="$STORAGE/$name.qcow2"
      if [ ! -f "$path" ] || [ ! -s "$path" ]; then
        path="$STORAGE/$name.img"
      fi ;;
  esac

  if [ ! -f "$path" ] || [ ! -s "$path" ]; then
    return 1
  fi

  printf '%s\n' "$path"
  return 0
}

hasDisk() {

  getDisk >/dev/null
  return $?

}

hasData() {

  local path
  local rc=0 tmp=""
  local bytes=102400

  path=$(getDisk) || return 1
  local source="$path"

  if [[ "${path,,}" == *.qcow2 ]]; then

    tmp=$(mktemp) || {
      warn "failed to create a temporary file while inspecting \"$path\"."
      return 0
    }

    if ! qemu-img dd -f qcow2 -O raw bs="$bytes" count=1 \
        "if=$path" "of=$tmp" >/dev/null 2>&1; then
      rm -f "$tmp"
      warn "failed to inspect disk \"$path\", assuming it contains data."
      return 0
    fi

    source="$tmp"

  fi

  # Treat a disk as empty only when its first 100 KiB are all zero. Inspection
  # failures are conservative and assume data is present to prevent replacement.
  cmp -s -n "$bytes" "$source" /dev/zero || rc=$?
  [ -n "$tmp" ] && rm -f "$tmp"

  case "$rc" in
    0) return 1 ;;
    1) return 0 ;;
  esac

  warn "failed to inspect disk \"$path\", assuming it contains data."
  return 0
}

addPackage() {

  local pkg=$1
  local desc=$2

  if apt-mark showinstall | grep -qx "$pkg"; then
    return 0
  fi

  local msg="Installing $desc..."
  info "$msg" && html "$msg"

  DEBIAN_FRONTEND=noninteractive apt-get -qq update || return 1
  DEBIAN_FRONTEND=noninteractive apt-get -qq --no-install-recommends -y install "$pkg" > /dev/null || return 1

  return 0
}

getAgent() {

  local browser_version

    # Advance the synthetic browser version periodically so download endpoints do
  # not reject a permanently stale user agent.
  browser_version="$((152 + ($(date +%s) - 1781568000) / 1209600))"
  echo "Mozilla/5.0 (X11; Linux x86_64; rv:${browser_version}.0) Gecko/20100101 Firefox/${browser_version}.0"

  return 0
}

delay() {

  local i
  local seconds="$1"
  local msg="Retrying failed download in X seconds..."

  info "${msg/X/$seconds}"

  for i in $(seq "$seconds" -1 1); do
    html "${msg/X/$i}"

    sleep 1 || {
      local rc=$?
      (( rc >= 129 )) && exit "$rc"
    }
  done

  return 0
}

updateAriaProgress() {

  local line="$1"
  local status_file="$2"
  local status_tmp="$3"

  [ -z "$status_file" ] && return 0

  if [[ "$line" == *" CN:"* &&
      "$line" =~ \#[[:xdigit:]]+[[:space:]]+([0-9]+)B/([0-9]+)B ]]; then
    local completed="${BASH_REMATCH[1]}"
    local total="${BASH_REMATCH[2]}"

    if ! printf '%s %s\n' "$completed" "$total" > "$status_tmp" ||
        ! mv -f -- "$status_tmp" "$status_file"; then
      rm -f -- "$status_tmp"
    fi
  fi

  return 0
}

showAriaLine() {

  local line="$1"
  local percent speed_size
  local current_size total_size

  [[ "$line" == *" CN:"* ]] || return 1

  if [[ ! "$line" =~ \#[[:xdigit:]]+[[:space:]]+([0-9]+)B/([0-9]+)B ]]; then
    return 1
  fi

  local current="${BASH_REMATCH[1]}"
  local total="${BASH_REMATCH[2]}"

  current_size=$(formatBytes "$current") || current_size="${current}B"
  total_size=$(formatBytes "$total") || total_size="${total}B"

  if (( total > 0 )); then
    local progress=$((current * 1000 / total))
    (( progress > 1000 )) && progress=1000

    printf -v percent '%d.%d' \
      "$((progress / 10))" \
      "$((progress % 10))"
  else
    percent="0.0"
  fi

  local output=$'\033[35m[ \033[0m'
  output+=$'\033[36m'"${percent}%"$'\033[0m'
  output+=" | $current_size / $total_size"

  if [[ "$line" =~ DL:([0-9]+)B ]]; then
    local speed="${BASH_REMATCH[1]}"
    speed_size=$(formatBytes "$speed") || speed_size="${speed}B"
    output+=$' | \033[32m'"$speed_size/s"$'\033[0m'
  fi

  if [[ "$line" =~ ETA:([^]]+) ]]; then
    local eta="${BASH_REMATCH[1]}"
    output+=$' | \033[33mETA '"$eta"$'\033[0m'
  fi

  output+=$'\033[35m ]\033[0m'

  printf '\r\033[K%s' "$output" >&2
  return 0
}

handleAriaLine() {

  local line="$1"
  local status_file="$2"
  local status_tmp="$3"
  local display="$4"

  updateAriaProgress "$line" "$status_file" "$status_tmp"

  [[ "$display" == "Y" ]] || return 1
  showAriaLine "$line"
}

filterAriaOutput() {

  local status_file="$1"
  local display="${2:-N}"
  local status_tmp="${status_file}.${BASHPID}"
  local char line="" shown="N"

  # Keep the filter alive while aria2 handles an interrupt gracefully.
  trap '' INT TERM

  # RETURN runs while status_tmp is still in the function's local scope.
  trap 'rm -f -- "$status_tmp"; trap - RETURN' RETURN

  # aria2 redraws one console line with carriage returns, so consume characters
  # rather than normal newline-delimited records.
  while IFS= read -r -N 1 char; do
    case "$char" in
      $'\r' | $'\n' )
        if handleAriaLine \
            "$line" \
            "$status_file" \
            "$status_tmp" \
            "$display"; then
          shown="Y"
        fi

        line="" ;;
      * )
        line+="$char" ;;
    esac
  done

  # Process a final unterminated console update.
  if [[ -n "$line" ]] &&
      handleAriaLine \
        "$line" \
        "$status_file" \
        "$status_tmp" \
        "$display"; then
    shown="Y"
  fi

  [[ "$shown" == "Y" ]] && printf '\n' >&2
  return 0
}

checkDownloadSpace() {

  local dest="$1"
  local expected="${2:-0}"
  local dir available
  local expected_size capacity_size

  [[ "$expected" =~ ^[1-9][0-9]*$ ]] || return 0

  dir=$(dirname -- "$dest")

  if [ ! -d "$dir" ]; then
    error "Failed to check free space because directory \"$dir\" does not exist!"
    return 1
  fi

  available=$(df --output=avail -B1 -- "$dir" 2>/dev/null |
    awk 'NR == 2 { print $1 }') || available=""

  if [[ ! "$available" =~ ^[0-9]+$ ]]; then
    error "Failed to check free space in $dir!"
    return 1
  fi

  local used=0

  # Existing blocks can be reused when the destination is resumed or replaced.
  if [ -f "$dest" ]; then
    used=$(du -sB1 -- "$dest" 2>/dev/null |
      awk 'NR == 1 { print $1 }') || used=""

    if [[ ! "$used" =~ ^[0-9]+$ ]]; then
      error "Failed to determine the allocated size of \"$dest\"!"
      return 1
    fi
  fi

  local capacity=$((available + used))

  if (( expected > capacity )); then
    expected_size=$(formatBytes "$expected") ||
      expected_size="$expected bytes"

    capacity_size=$(formatBytes "$capacity") ||
      capacity_size="$capacity bytes"

    error "Not enough free space to download file, $expected_size required but only $capacity_size available!"
    return 1
  fi

  return 0
}

startDownloadProgress() {

  local log_name="$1"
  local status_name="$2"
  local pid_name="$3"
  local dest="$4"
  local expected="$5"
  local message="$6"
  local output="$7"
  local interval="$8"
  local connections="$9"
  local progress_path="$dest"
  local progress_mode="apparent"
  local log_value status_value=""

  if ! log_value=$(mktemp -p "$QEMU_DIR"); then
    error "Failed to create temporary download log!"
    return 2
  fi

  if (( connections > 1 )); then
    if ! status_value=$(mktemp -p "$QEMU_DIR"); then
      rm -f -- "$log_value"
      error "Failed to create temporary aria2 progress status!"
      return 2
    fi

    if ! printf '0 0\n' > "$status_value"; then
      rm -f -- "$log_value" "$status_value"
      error "Failed to initialize temporary aria2 progress status!"
      return 2
    fi

    progress_path="$status_value"
    progress_mode="counter"
  fi

  # Start progress.sh before opening the aria output pipe so it cannot
  # inherit the pipe's write descriptor and prevent the filter from exiting.
  /run/progress.sh \
    "$progress_path" \
    "$expected" \
    "$message ([P])..." \
    "$output" \
    "$interval" \
    "$progress_mode" \
    "$status_value" &

  local pid_value="$!"

  printf -v "$log_name" '%s' "$log_value"
  printf -v "$status_name" '%s' "$status_value"
  printf -v "$pid_name" '%s' "$pid_value"
  return 0
}

stopDownloadProgress() {

  local pid="$1"
  local status="$2"

  if [ -n "$pid" ]; then
    kill -TERM "$pid" 2>/dev/null || :
    wait "$pid" 2>/dev/null || :
  fi

  [ -n "$status" ] && rm -f -- "$status"
  return 0
}

downloadWithAria() {

  local rc_name="$1"
  local signal_name="$2"
  local status="$3"
  local aria_display="$4"
  local dest="$5"
  shift 5

  local aria_fd download_pid=""
  local int_trap term_trap total
  local cancel_signal_value=""

  # Use a dedicated descriptor for aria2 stderr so progress filtering can finish
  # independently and the downloader's exit status remains available.
  if ! exec {aria_fd}> >(filterAriaOutput "$status" "$aria_display"); then
    error "Failed to create aria2 output filter!"
    return 2
  fi

  local filter_pid="$!"
  int_trap=$(trap -p INT)
  term_trap=$(trap -p TERM)

  # Forward cancellation to aria2 while retaining the caller's original traps;
  # they are restored after the filter and downloader have exited.
  trap '
    cancel_signal_value="INT"
    [ -n "$download_pid" ] &&
      kill -INT -- "$download_pid" 2>/dev/null || :
  ' INT

  trap '
    cancel_signal_value="TERM"
    [ -n "$download_pid" ] &&
      kill -TERM -- "$download_pid" 2>/dev/null || :
  ' TERM

  (
    trap - INT TERM
    export LC_ALL=C
    exec "$@" 2>&"$aria_fd"
  ) &

  download_pid=$!

  # Cover a signal arriving between starting aria2 and recording its PID.
  if [ -n "$cancel_signal_value" ]; then
    kill -"$cancel_signal_value" -- "$download_pid" 2>/dev/null || :
  fi

  while true; do
    local rc_value=0
    wait "$download_pid" || rc_value=$?

    isAlive "$download_pid" || break
  done

  download_pid=""

  # Aria may exit successfully before emitting its final console update.
  # Use the completed file size instead of the asynchronously updated status
  # file, then send a final update through the existing output filter.
  if (( rc_value == 0 )) && [ -f "$dest" ]; then
    total=$(stat -c%s -- "$dest" 2>/dev/null) || total=""

    if [[ "$total" =~ ^[1-9][0-9]*$ ]]; then
      printf '\r#000000 %sB/%sB CN:0\r' \
        "$total" \
        "$total" >&"$aria_fd" || :
    fi
  fi

  exec {aria_fd}>&-
  wait "$filter_pid" 2>/dev/null || :

  if [ -n "$int_trap" ]; then
    eval "$int_trap"
  else
    trap - INT
  fi

  if [ -n "$term_trap" ]; then
    eval "$term_trap"
  else
    trap - TERM
  fi

  printf -v "$rc_name" '%s' "$rc_value"
  printf -v "$signal_name" '%s' "$cancel_signal_value"
  return 0
}

getDownloadFailureReason() {

  local connections="$1"
  local log="$2"
  local reason

  if (( connections > 1 )); then
    reason=$(sed -nE \
      -e 's/^[[:space:]]*->[[:space:]]*(\[[^]]+\][[:space:]]*)?(errorCode=[0-9]+[[:space:]]*)?(CUID#[0-9]+[[:space:]]*-[[:space:]]*)?//p' \
      -e 's/^.*\[ERROR\][[:space:]]*(CUID#[0-9]+[[:space:]]*-[[:space:]]*)?//p' \
      "$log" | tail -n 1)

    if [ -z "$reason" ]; then
      reason=$(awk 'NF { line=$0 } END { print line }' "$log")

      reason=$(sed -E \
        's/^(CUID#[0-9]+[[:space:]]*-[[:space:]]*)?//' \
        <<< "$reason")
    fi

  else

    reason=$(sed -n \
      -e 's/^wget: //p' \
      -e 's/^[0-9-]\{10\} [0-9:]\{8\} ERROR //p' \
      "$log" | tail -n 1)

  fi

  printf '%s' "$reason"
  return 0
}

handleDownloadCancellation() {

  local signal="$1"
  local connections="$2"
  local rc="$3"
  local log="$4"

  if [ -z "$signal" ] &&
      ! (( connections > 1 && rc == 7 )); then
    return 0
  fi

  rm -f -- "$log"

  case "${signal:-INT}" in
    TERM )
      kill -TERM "$BASHPID"
      exit 143 ;;
    * )
      kill -INT "$BASHPID"
      exit 130 ;;
  esac
}

downloadToFile() {

  if (( $# < 3 )); then
    error "downloadToFile requires a URL, destination and message."
    return 2
  fi

  local url="$1"
  local dest="$2"
  local message="$3"
  local expected="${4:-0}"
  local connections="${5:-1}"
  local resume="${6:-Y}"
  local request=()

  if (( $# > 6 )); then
    shift 6
    request=("$@")
  fi

  local progress=()
  local wget_resume=()
  local aria_display="N"
  local aria_resume="false"
  local allocation="none"
  local default_interval=536870912
  local interval="$default_interval"
  local progress_pid status log
  local dir file option rc run_rc=0
  local agent custom_agent="N"
  local output="" reason=""
  local cancel_signal=""
  local probe=""

  if [[ ! "$connections" =~ ^[1-9][0-9]*$ ]]; then
    error "Invalid connection count: $connections"
    return 2
  fi

  if [[ ! "$expected" =~ ^[0-9]+$ ]]; then
    expected=0
  fi

  dir=$(dirname -- "$dest")

  if [ ! -d "$dir" ]; then
    error "Download destination directory \"$dir\" does not exist!"
    return 2
  fi

  if ! checkDownloadSpace "$dest" "$expected"; then
    return 2
  fi

  if (( expected > 0 )); then
    interval=$(((expected + 9) / 10))
  fi

  if enabled "$resume"; then
    wget_resume=( --continue )
    aria_resume="true"
  fi

  # Allow callers such as macOS recovery to provide a protocol-specific
  # user agent while applying the normal browser agent everywhere else.
  for option in "${request[@]}"; do
    case "$option" in
      --user-agent | --user-agent=* | -U | -U* )
        custom_agent="Y"
        break ;;
    esac
  done

  if [[ "$custom_agent" != "Y" ]]; then
    if ! agent=$(getAgent) || [ -z "$agent" ]; then
      error "Failed to generate a download user agent!"
      return 2
    fi

    request=( --user-agent "$agent" "${request[@]}" )
  fi

  if (( connections > 1 )); then
    if ! command -v aria2c >/dev/null; then
      error "aria2c is required when using multiple download connections."
      return 1
    fi

    # Test the destination filesystem directly instead of maintaining an
    # incomplete filesystem blacklist. Unsupported filesystems fall back to
    # no preallocation while retaining multi-connection downloads.
    if command -v fallocate >/dev/null &&
        probe=$(mktemp -p "$dir" .fallocate.XXXXXX 2>/dev/null); then

      if fallocate -l 1048576 "$probe" 2>/dev/null; then
        allocation="falloc"
      fi

      rm -f -- "$probe" || :
    fi

  elif ! command -v wget >/dev/null; then
    error "The wget command was not found."
    return 2
  fi

  # Use the downloader's progress display in a terminal
  # and progress.sh in container logs and the web viewer.
  if [ -t 0 ] && [ -t 2 ]; then
    if (( connections > 1 )); then
      aria_display="Y"
    else
      progress=( --show-progress --progress=bar:noscroll )
    fi
  else
    output="log"
  fi

  html "$message..."

  startDownloadProgress \
    log \
    status \
    progress_pid \
    "$dest" \
    "$expected" \
    "$message" \
    "$output" \
    "$interval" \
    "$connections" || return $?

  enabled "${DEBUG:-N}" && echo "Downloading: $url"

  if (( connections > 1 )); then

    file=$(basename -- "$dest")

    downloadWithAria \
      rc \
      cancel_signal \
      "$status" \
      "$aria_display" \
      "$dest" \
      aria2c \
      --no-conf=true \
      --dir="$dir" \
      --out="$file" \
      --split="$connections" \
      --max-connection-per-server="$connections" \
      --file-allocation="$allocation" \
      --continue="$aria_resume" \
      --always-resume=false \
      --allow-overwrite=true \
      --auto-file-renaming=false \
      --max-tries=2 \
      --retry-wait=2 \
      --lowest-speed-limit=10K \
      --connect-timeout=30 \
      --timeout=30 \
      --async-dns=false \
      --follow-metalink=false \
      --follow-torrent=false \
      --stderr=true \
      --summary-interval=0 \
      --show-console-readout=true \
      --truncate-console-readout=true \
      --download-result=hide \
      --console-log-level=error \
      --enable-color=false \
      --human-readable=false \
      --log="$log" \
      --log-level=error \
      "${request[@]}" \
      -- "$url" || run_rc=$?

  else

    {
      LC_ALL=C wget \
        --output-document="$dest" \
        "${wget_resume[@]}" \
        --no-verbose \
        --timeout=30 \
        --no-http-keep-alive \
        "${progress[@]}" \
        --output-file="$log" \
        "${request[@]}" \
        -- "$url"

      rc=$?
    } || :

  fi

  stopDownloadProgress "$progress_pid" "$status"

  if (( run_rc != 0 )); then
    rm -f -- "$log"

    if (( run_rc >= 129 )); then
      exit "$run_rc"
    fi

    return "$run_rc"
  fi

  # Aria normally returns 7 after cancellation, but a concurrent download
  # error can take precedence. Track the signal so cancellation is not retried.
  handleDownloadCancellation "$cancel_signal" "$connections" "$rc" "$log"

  if (( rc >= 129 )); then
    rm -f -- "$log"
    exit "$rc"
  fi

  if (( rc != 0 )); then
    reason=$(getDownloadFailureReason "$connections" "$log")
  fi

  if (( rc != 0 )) && enabled "${DEBUG:-N}" && [ -s "$log" ]; then
    printf '\n' >&2
    cat "$log" >&2
  fi

  rm -f -- "$log"

  if (( rc == 0 )) && [ -f "$dest" ]; then
    # Aria normally removes this itself after successful completion.
    rm -f -- "$dest.aria2"
    return 0
  fi

  local failure="Failed to download $url"

  if (( connections == 1 && rc == 3 )); then
    error "$failure because the file could not be written (disk full?)."
  elif (( connections > 1 && rc == 9 )); then
    error "$failure because there was not enough disk space."
  elif [ -n "$reason" ]; then
    error "$failure : ${reason%.}."
  elif (( rc == 0 )); then
    error "$failure because no output file was created."
  else
    error "$failure with exit status $rc."
  fi

  if (( connections == 1 && rc == 3 )) ||
      (( connections > 1 && rc == 9 )); then
    return 2
  fi

  return 1
}

validateDownloadMinimum() {

  local dest="$1"
  local minimum="${2:-0}"
  local actual actual_size minimum_size

  if [[ ! "$minimum" =~ ^[0-9]+$ ]]; then
    error "Invalid minimum download size: $minimum"
    return 2
  fi

  (( minimum == 0 )) && return 0

  if ! actual=$(stat -c%s -- "$dest" 2>/dev/null); then

    error "Failed to determine downloaded file size: $dest"

  elif (( actual < minimum )); then

    actual_size=$(formatBytes "$actual") ||
      actual_size="$actual bytes"

    minimum_size=$(formatBytes "$minimum") ||
      minimum_size="$minimum bytes"

    error "Downloaded file is only $actual_size, but at least $minimum_size was expected."

  else

    return 0

  fi

  # The failed result must not be resumed during the next attempt.
  if ! rm -f -- "$dest" "$dest.aria2"; then
    error "Failed to remove invalid download \"$dest\"!"
    return 2
  fi

  return 1
}

downloadRetry() {

  if (( $# < 5 )); then
    error "downloadRetry requires a destination, connection count, delay, description and minimum size."
    return 2
  fi

  local dest="$1"
  local connections="$2"
  local seconds="$3"
  local description="$4"
  local minimum="$5"
  shift 5

  if [[ ! "$connections" =~ ^[1-9][0-9]*$ ]] ||
      (( connections > 16 )); then
    error "The CONNECTIONS value must be between 1 and 16!"
    return 2
  fi

  if [[ ! "$seconds" =~ ^[0-9]+$ ]]; then
    error "Invalid retry delay: $seconds"
    return 2
  fi

  if [[ ! "$minimum" =~ ^[0-9]+$ ]]; then
    error "Invalid minimum download size: $minimum"
    return 2
  fi

  # Retry policy intentionally starts clean: deterministic validation failures
  # and stale aria metadata must never be resumed as if they were valid data.
  # Always start without stale partial or aria control files.
  if ! rm -f -- "$dest" "$dest.aria2"; then
    error "Failed to remove previous download \"$dest\"!"
    return 2
  fi

  # Try the configured number of connections first.
  if downloadFile "$@" "$connections"; then

    if validateDownloadMinimum "$dest" "$minimum"; then
      return 0
    else
      local rc=$?
    fi

  else

    local rc=$?

  fi

  delay "$seconds"

  # A multi-connection partial file can contain non-sequential
  # ranges and cannot safely be resumed by Wget.
  if (( connections > 1 )); then

    if ! rm -f -- "$dest" "$dest.aria2"; then
      error "Failed to remove partial download \"$dest\"!"
      return 2
    fi

  fi

  info "Retrying $description with a single connection..."

  # Retry using single-connection Wget.
  if downloadFile "$@" "1"; then

    if validateDownloadMinimum "$dest" "$minimum"; then
      return 0
    else
      local rc=$?
    fi

  else

    local rc=$?

  fi

  if ! rm -f -- "$dest" "$dest.aria2"; then
    warn "failed to remove failed download \"$dest\"!"
  fi

  return "$rc"
}

return 0
