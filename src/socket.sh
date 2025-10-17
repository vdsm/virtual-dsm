#!/usr/bin/env bash
set -Eeuo pipefail

lastmsg=""
path="/run/shm/msg.html"

refresh() {

  [ ! -f "$path" ] && return 0
  [ ! -s "$path" ] && return 0

  msg=$(< "$path")
  msg="${msg%$'\n'}"

  [ -z "$msg" ] && return 0
  [[ "$msg" == "$lastmsg" ]] && return 0

  lastmsg="$msg"
  echo "s: $msg"
  return 0
}

refresh

inotifywait -m "$path" |
  while read -r fp event fn; do
    case "${event,,}" in
      "modify"* ) refresh ;;
      "delete_self" ) echo "c: vnc" ;;
    esac    
  done
