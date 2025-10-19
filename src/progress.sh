#!/usr/bin/env bash
set -Eeuo pipefail

info="/run/shm/msg.html"

escape () {
    local s
    s=${1//&/\&amp;}
    s=${s//</\&lt;}
    s=${s//>/\&gt;}
    s=${s//'"'/\&quot;}
    printf -- %s "$s"
    return 0
}

path="$1"
total="$2"
body=$(escape "$3")

if [[ "$body" == *"..." ]]; then
  body="<p class=\"loading\">${body::-3}</p>"
fi

while true
do

  if [ ! -s "$path" ] && [ ! -d "$path" ]; then
    bytes="0"
  else
    bytes=$(du -sb "$path" | cut -f1)
  fi
  
  if (( bytes > 4096 )); then
    if [ -z "$total" ] || [[ "$total" == "0" ]] || [ "$bytes" -gt "$total" ]; then
      size=$(numfmt --to=iec --suffix=B "$bytes" | sed -r 's/([A-Z])/ \1/')
    else
      size="$(echo "$bytes" "$total" | awk '{printf "%.1f", $1 * 100 / $2}')"
      size="$size%"
    fi
    [[ "$size" != "0.0%" ]] && echo "${body//(\[P\])/($size)}"> "$info"
  fi

  sleep 1 & wait $!

done
