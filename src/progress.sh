#!/usr/bin/env bash
set -Eeuo pipefail

info="/run/shm/msg.html"
info_tmp="${info}.${BASHPID}.tmp"

escape() {

  local s

  s=${1//&/\&amp;}
  s=${s//</\&lt;}
  s=${s//>/\&gt;}
  s=${s//'"'/\&quot;}
  s=${s//"'"/\&#39;}

  printf '%s' "$s"
  return 0
}

writeInfo() {

  local content="$1"

  if ! printf '%s\n' "$content" > "$info_tmp"; then
    rm -f -- "$info_tmp"
    return 1
  fi

  if ! mv -f -- "$info_tmp" "$info"; then
    rm -f -- "$info_tmp"
    return 1
  fi

  return 0
}

getBytes() {

  local path="$1"
  local mode="$2"
  local bytes="0"

  if [[ "$mode" == "counter" ]]; then
    if [ -r "$path" ]; then
      read -r bytes < "$path" || bytes="0"
    fi

    [[ "$bytes" =~ ^[0-9]+$ ]] || bytes="0"
    printf '%s\n' "$bytes"
    return 0
  fi

  if [ ! -s "$path" ] && [ ! -d "$path" ]; then
    printf '0\n'
    return 0
  fi

  if [[ "$mode" == "allocated" ]]; then
    bytes=$(du -sB1 -- "$path" 2>/dev/null | cut -f1) || bytes="0"
  else
    bytes=$(du -sb -- "$path" 2>/dev/null | cut -f1) || bytes="0"
  fi

  printf '%s\n' "$bytes"
  return 0
}

getStatus() {

  local file="$1"
  local bytes total extra=""

  [ -r "$file" ] || return 1
  read -r bytes total extra < "$file" || return 1

  if [[ ! "$bytes" =~ ^[0-9]+$ ||
        ! "$total" =~ ^[0-9]+$ ||
        -n "$extra" ]]; then
    return 1
  fi

  printf '%s %s\n' "$bytes" "$total"
  return 0
}

formatSize() {

  local bytes="$1"
  local size

  size=$(numfmt --to=iec --suffix=B "$bytes" |
    sed -r 's/([A-Z])/ \1/') ||
    size="${bytes} bytes"

  printf '%s' "$size"
  return 0
}

printPercentProgress() {

  local percent="$1"

  while (( next_percent <= percent && next_percent <= 100 )); do
    if [[ "$printed" == "Y" ]]; then
      printf ' → %s%%' "$next_percent"
    else
      printf '%s%%' "$next_percent"
    fi

    printed="Y"
    next_percent=$((next_percent + 10))
  done

  return 0
}

printCurrentSize() {

  local bytes="$1"
  local size

  size=$(formatSize "$bytes")

  if [[ "$printed" == "Y" ]]; then
    printf ' → %s' "$size"
  else
    printf '%s' "$size"
  fi

  printed="Y"
  return 0
}

printSizeProgress() {

  local bytes="$1"
  local size

  while (( bytes >= next_bytes )); do
    size=$(formatSize "$next_bytes")

    if [[ "$printed" == "Y" ]]; then
      printf ' → %s' "$size"
    else
      printf '%s' "$size"
    fi

    printed="Y"
    next_bytes=$((next_bytes + step_bytes))
  done

  return 0
}

finishProgress() {

  rm -f -- "$info_tmp"

  if [[ "$output" == "log" && "$printed" == "Y" ]]; then
    printf '\n'
  fi

  return 0
}

path="$1"
total="$2"
body=$(escape "$3")
output="${4:-}"
step_bytes="${5:-536870912}"
mode="${6:-apparent}"
status_file="${7:-}"

if [[ -n "$total" && ! "$total" =~ ^(0|[1-9][0-9]*)$ ]]; then
  printf 'Invalid total size: %s\n' "$total" >&2
  exit 2
fi

if [[ ! "$step_bytes" =~ ^[1-9][0-9]*$ ]]; then
  printf 'Invalid progress interval: %s\n' "$step_bytes" >&2
  exit 2
fi

case "$mode" in
  apparent | allocated | counter ) ;;
  * )
    printf 'Invalid progress mode: %s\n' "$mode" >&2
    exit 2
    ;;
esac

case "$output" in
  "" | log ) ;;
  * )
    printf 'Invalid progress output: %s\n' "$output" >&2
    exit 2
    ;;
esac

printed="N"
next_percent=10
next_bytes="$step_bytes"
log_mode="percent"

if [ -z "$total" ] || [[ "$total" == "0" ]]; then
  log_mode="size"
fi

trap finishProgress EXIT
trap 'exit 0' HUP INT QUIT TERM

if [[ "$body" == *"..." ]]; then
  body="<p class=\"loading\">${body::-3}</p>"
fi

while true; do

  bytes=$(getBytes "$path" "$mode")
  effective_total="$total"

  if [ -n "$status_file" ] && status=$(getStatus "$status_file"); then
    read -r status_bytes status_total <<< "$status"
    bytes="$status_bytes"

    if (( status_total > 0 )); then
      effective_total="$status_total"
    fi
  fi

  # A real total may become available shortly after aria2 starts.
  if [[ "$log_mode" == "size" &&
        "$printed" == "N" &&
        -n "$effective_total" &&
        "$effective_total" != "0" ]]; then
    log_mode="percent"
  fi

  if (( bytes > 4096 )); then

    write_html="Y"

    if [ -z "$effective_total" ] ||
        [[ "$effective_total" == "0" ]] ||
        (( bytes > effective_total )); then
      size=$(formatSize "$bytes")

      if [[ "$output" == "log" ]]; then
        if [[ "$log_mode" == "percent" ]]; then
          printCurrentSize "$bytes"
          next_bytes=$(((bytes / step_bytes + 1) * step_bytes))
          log_mode="size"
        else
          printSizeProgress "$bytes"
        fi
      fi
    else
      # Truncate to one decimal so progress is never reported early.
      progress=$((bytes * 1000 / effective_total))
      (( progress > 1000 )) && progress=1000

      percent=$((progress / 10))

      printf -v size '%d.%d%%' \
        "$((progress / 10))" \
        "$((progress % 10))"

      if [[ "$output" == "log" ]]; then
        if [[ "$log_mode" == "size" ]]; then
          printSizeProgress "$bytes"
        else
          printPercentProgress "$percent"
        fi
      fi

      # Do not update the web viewer until at least 0.1% is reached.
      (( progress == 0 )) && write_html="N"
    fi

    if [[ "$write_html" == "Y" ]]; then
      writeInfo "${body//(\[P\])/($size)}"
    fi
  fi

  sleep 1 & wait $!
done
