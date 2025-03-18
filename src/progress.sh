#!/usr/bin/env bash
set -Eeuo pipefail

escape () {
    local s
    s=${1//&/\&amp;}
    s=${s//</\&lt;}
    s=${s//>/\&gt;}
    s=${s//'"'/\&quot;}
    printf -- %s "$s"
    return 0
}

file="$1"
total="$2"
body=$(escape "$3")
info="/run/shm/msg.html"

if [[ "$body" == *"..." ]]; then
  body="<p class=\"loading\">${body/.../}</p>"
fi

while true
do
  if [ -s "$file" ]; then
    bytes=$(du -sb "$file" | cut -f1)
    if (( bytes > 1000 )); then
      if [ -z "$total" ] || [[ "$total" == "0" ]]; then
        size=$(numfmt --to=iec --suffix=B "$bytes" | sed -r 's/([A-Z])/ \1/')
      else
        size="$(echo "$bytes" "$total" | awk '{printf "%.1f", $1 * 100 / $2}')"
        size="$size%"
      fi
      echo "${body//(\[P\])/($size)}"> "$info"
    fi
  fi
  sleep 1 & wait $!
done
