#!/usr/bin/env bash

set -eu

HTML="<HTML><BODY><H1><CENTER>Please wait while Virtual DSM is installing...</CENTER></H1></BODY></HTML>"
RESPONSE="HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n$HTML\r\n"

while { echo -en "$RESPONSE"; } | nc -lN "${1:-8080}"; do
  echo "================================================"
done

