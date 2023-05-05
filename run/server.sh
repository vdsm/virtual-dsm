#!/usr/bin/env bash
set -eu

trap 'kill 0' EXIT
trap exit SIGINT SIGTERM

# Serve the page
HTML="<!DOCTYPE html><HTML><HEAD><TITLE>VirtualDSM</TITLE><STYLE>body { color: white; background-color: #125bdb; font-family: Verdana,\
Arial,sans-serif; } a, a:hover, a:active, a:visited { color: white; }</STYLE></HEAD><BODY><BR><BR><H1><CENTER>$2</CENTER></H1></BODY></HTML>"

LENGTH="${#HTML}"

RESPONSE="HTTP/1.1 200 OK\nContent-Length: ${LENGTH}\nConnection: close\n\n$HTML\n\n"

while true; do
  echo -en "$RESPONSE" | nc -lp "${1:-5000}" & wait $!
done
