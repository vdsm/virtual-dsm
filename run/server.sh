#!/usr/bin/env bash
set -eu
trap exit SIGINT SIGTERM

# Close any previous instances
script_name=${BASH_SOURCE[0]}

for pid in $(pidof -x $script_name); do
  if [ $pid != $$ ]; then
    kill -15 $pid 2> /dev/null
    wait $pid 2> /dev/null
  fi 
done

# Serve the page
HTML="<HTML><BODY><H1><CENTER>$2</CENTER></H1></BODY></HTML>"
RESPONSE="HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n$HTML\r\n"

while true; do (echo -en "$RESPONSE") | timeout 1 nc -lp "${1:-8080}"; done
