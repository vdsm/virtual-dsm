#!/usr/bin/env bash
set -Eeuo pipefail

path="/run/shm/msg.html"

inotifywait -m "$path" |
  while read -r fp event fn; do
    case "${event,,}" in
      "modify" ) echo -n "s: " && cat "$path" ;;
      "delete_self" ) echo "c: vnc" ;;
    esac    
  done
