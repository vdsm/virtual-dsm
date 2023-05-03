#!/usr/bin/env bash
set -eu
trap exit SIGINT SIGTERM

# Serve the page
HTML="<HTML><HEAD><STYLE>body {  color: white; background-color: #00BFFF; }</STYLE>\
              </HEAD><BODY><BR><BR><H1><CENTER>$2</CENTER></H1></BODY></HTML>"

LENGTH="${#HTML}"

RESPONSE="HTTP/1.1 200 OK\nContent-Length: ${LENGTH}\nConnection: close\n\n$HTML\n\n"

while true; do
  echo -en "$RESPONSE" | nc -lp "${1:-5000}" & wait $!
done
