#!/usr/bin/env bash
set -eu

trap 'pkill -f nc || true' EXIT
trap exit SIGINT SIGTERM

if [[ "$2" == "/"* ]]; then

  while true ; do
    nc -lp "${1:-5000}" -e "$2" >/dev/null 2>&1 & wait $!
  done

else

  HTML="<!DOCTYPE html><HTML><HEAD><TITLE>VirtualDSM</TITLE><STYLE>body { color: white; background-color: #125bdb; font-family: Verdana,\
        Arial,sans-serif; } a, a:hover, a:active, a:visited { color: white; }</STYLE></HEAD><BODY><BR><BR><H1><CENTER>$2</CENTER></H1></BODY></HTML>"

  LENGTH="${#HTML}"
  RESPONSE="HTTP/1.1 200 OK\nContent-Length: ${LENGTH}\nConnection: close\n\n$HTML\n\n"

  while true; do
    echo -en "$RESPONSE" | nc -lp "${1:-5000}" >/dev/null 2>&1 & wait $!
  done

fi
