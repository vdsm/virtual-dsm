#!/usr/bin/env bash
set -Eeuo pipefail

info="/run/shm/msg.html"

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

getBytes() {

  local path="$1"
  local mode="$2"
  local bytes

  if [ ! -s "$path" ] && [ ! -d "$path" ]; then
    echo "0"
    return 0
  fi

  if [[ "$mode" == "allocated" ]]; then
    bytes=$(du -sB1 -- "$path" 2>/dev/null | cut -f1) || bytes="0"
  else
    bytes=$(du -sb -- "$path" 2>/dev/null | cut -f1) || bytes="0"
  fi

  echo "$bytes"
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

printSizeProgress() {

  local bytes="$1"
  local size

  while (( bytes >= next_bytes )); do
    size=$(numfmt --to=iec-i --suffix=B "$next_bytes") ||
      size="${next_bytes} bytes"

    size="${size/.0MiB/MiB}"
    size="${size/.0GiB/GiB}"

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

finishLogProgress() {

  if [[ "$output" == "log" && "$printed" == "Y" ]]; then
    printf '\n'
  fi

  return 0
}

path="$1"
total="$2"
body=$(escape "$3")
output="${4:-}"
mode="${5:-apparent}"
step_bytes="${6:-52428800}"

if [[ ! "$step_bytes" =~ ^[1-9][0-9]*$ ]]; then
  echo "Invalid progress interval: $step_bytes" >&2
  exit 2
fi

printed="N"
next_percent=10
next_bytes="$step_bytes"

trap finishLogProgress EXIT

if [[ "$body" == *"..." ]]; then
  body="<p class=\"loading\">${body::-3}</p>"
fi

while true; do

  bytes=$(getBytes "$path" "$mode")

  if (( bytes > 4096 )); then
    if [ -z "$total" ] || [[ "$total" == "0" ]] || (( bytes > total )); then
      size=$(numfmt --to=iec-i --suffix=B "$bytes") ||
        size="${bytes} bytes"

      size="${size/.0MiB/MiB}"
      size="${size/.0GiB/GiB}"

      if [[ "$output" == "log" ]]; then
        printSizeProgress "$bytes"
      fi
    else
      progress=$((bytes * 1000 / total))
      (( progress > 1000 )) && progress=1000

      percent=$((progress / 10))
      printf -v size '%d.%d%%' "$((progress / 10))" "$((progress % 10))"

      if [[ "$output" == "log" ]]; then
        printPercentProgress "$percent"
      fi
    fi

    [[ "$size" != "0.0%" ]] && echo "${body//(\[P\])/($size)}" > "$info"
  fi

  sleep 1 & wait $!
done
