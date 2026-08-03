#!/usr/bin/env bash
set -Eeuo pipefail

lastmsg=""
path="/run/shm/msg.html"
dir=$(dirname -- "$path")
name=$(basename -- "$path")

refresh() {

  [ ! -f "$path" ] && return 0
  [ ! -s "$path" ] && return 0

  msg=$(< "$path") || return 0
  msg="${msg%$'\n'}"

  [ -z "$msg" ] && return 0
  [[ "$msg" == "$lastmsg" ]] && return 0

  lastmsg="$msg"
  # websocketd clients interpret s: as a status update and c: as a command;
  # suppress unchanged status to avoid redundant browser work.
  echo "s: $msg"

  return 0
}

refresh

inotifywait \
  -m -q \
  -e close_write,moved_to,delete \
  --format '%e %f' \
  "$dir" |
  while read -r event file; do

    [[ "$file" == "$name" ]] || continue

    case "${event,,}" in
      "delete"* )
        echo "c: vnc" ;;
      # moved_to covers the atomic replacement used by html()/writeAtomic(),
      # while close_write handles direct writers.
      "close_write"* | "moved_to"* )
        refresh ;;
    esac

  done
