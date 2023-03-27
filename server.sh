#!/usr/bin/env bash

set -eu

RESPONSE="HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n${2:-"OK"}\r\n"

while { echo -en "$RESPONSE"; } | nc -lN "${1:-8080}"; do
  echo "================================================"
done

