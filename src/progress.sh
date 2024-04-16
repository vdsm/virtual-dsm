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
body=$(escape "$2")
info="/run/shm/msg.html"

if [[ "$body" == *"..." ]]; then
  body="<p class=\"loading\">${body/.../}</p>"
fi

while true
do
  if [ -s "$file" ]; then
    bytes=$(du -sb "$file" | cut -f1)
    if (( bytes > 1000 )); then
      size=$(echo "$bytes" | numfmt --to=iec --suffix=B  | sed -r 's/([A-Z])/ \1/')
      echo "${body//(\[P\])/($size)}"> "$info"
    fi
  fi
  sleep 1 & wait $!
done
