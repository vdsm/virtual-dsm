#!/usr/bin/env bash
set -Eeuo pipefail

lastmsg=""
lastcmd=""
status="/run/shm/msg.html"
command="/run/shm/status.cmd"
dir=$(dirname -- "$status")
status_name=$(basename -- "$status")
command_name=$(basename -- "$command")

# websocketd clients use s: for status updates and c: for control commands.
refreshStatus() {

  [ ! -f "$status" ] && return 0
  [ ! -s "$status" ] && return 0

  msg=$(< "$status") || return 0
  msg="${msg%$'\n'}"

  [ -z "$msg" ] && return 0
  [[ "$msg" == "$lastmsg" ]] && return 0

  lastmsg="$msg"
  echo "s: $msg"

  return 0
}

refreshCommand() {

  [ ! -f "$command" ] && return 0
  [ ! -s "$command" ] && return 0

  cmd=$(< "$command") || return 0
  cmd="${cmd%$'\n'}"

  [ -z "$cmd" ] && return 0
  [[ "$cmd" == "$lastcmd" ]] && return 0

  lastcmd="$cmd"
  echo "c: $cmd"

  return 0
}

refreshStatus
refreshCommand

# Watch the directory because status and command updates use atomic rename.
inotifywait \
  -m -q \
  -e close_write,moved_to \
  --format '%e %f' \
  "$dir" |
  while read -r event file; do

    case "$file" in
      "$status_name" )
        case "${event,,}" in
          "close_write"* | "moved_to"* )
            refreshStatus ;;
        esac ;;
      "$command_name" )
        case "${event,,}" in
          "close_write"* | "moved_to"* )
            refreshCommand ;;
        esac ;;
    esac

  done
