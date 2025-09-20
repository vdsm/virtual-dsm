#!/usr/bin/env bash
set -Eeuo pipefail

# Helper functions

info () { printf "%b%s%b" "\E[1;34m❯ \E[1;36m" "${1:-}" "\E[0m\n"; }
error () { printf "%b%s%b" "\E[1;31m❯ " "ERROR: ${1:-}" "\E[0m\n" >&2; }
warn () { printf "%b%s%b" "\E[1;31m❯ " "Warning: ${1:-}" "\E[0m\n" >&2; }

formatBytes() {
  local result
  result=$(numfmt --to=iec --suffix=B "$1" | sed -r 's/([A-Z])/ \1/' | sed 's/ B/ bytes/g;')
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

  if kill -0 "$pid" 2>/dev/null; then
    return 0
  fi

  return 1
}

pKill() {
  local pid="$1"

  { kill -15 "$pid" || true; } 2>/dev/null

  while isAlive "$pid"; do
    sleep 0.2
  done

  return 0
}

fWait() {
  local name="$1"

  while pgrep -f -l "$name" >/dev/null; do
    sleep 0.2
  done

  return 0
}

fKill() {
  local name="$1"

  { pkill -f "$name" || true; } 2>/dev/null
  fWait "$name"

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

  echo "$HTML" > "$PAGE"
  echo "$body" > "$INFO"

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
  cpu="${cpu// [0-9] Core}"
  cpu="${cpu// [0-9][0-9] Core}"
  cpu="${cpu// [0-9][0-9][0-9] Core}"
  cpu="${cpu// [0-9]th Gen}"
  cpu="${cpu// [0-9][0-9]th Gen}"
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

hasDisk() {

  [ -b "/disk" ] && return 0
  [ -b "/disk1" ] && return 0
  [ -b "/dev/disk1" ] && return 0
  [ -b "${DEVICE:-}" ] && return 0

  [ -z "${DISK_NAME:-}" ] && DISK_NAME="data"
  [ -s "$STORAGE/$DISK_NAME.img" ]  && return 0
  [ -s "$STORAGE/$DISK_NAME.qcow2" ] && return 0

  return 1
}

return 0
