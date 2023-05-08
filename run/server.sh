#!/usr/bin/env bash
set -eu

TMP_FILE=""

stop() {
  trap - SIGINT EXIT
  { pkill -f socat || true; } 2>/dev/null
  [ -f "$TMP_FILE" ] && rm -f "$TMP_FILE"
}

trap 'stop' EXIT SIGINT SIGTERM SIGHUP

if [[ "$2" == "/"* ]]; then

  socat TCP4-LISTEN:"${1:-5000}",reuseaddr,fork,crlf SYSTEM:"$2" 2> /dev/null & wait $!

else

  HTML="<!DOCTYPE html><HTML><HEAD><TITLE>VirtualDSM</TITLE><STYLE>body { color: white; background-color: #125bdb; font-family: Verdana,\
        Arial,sans-serif; } a, a:hover, a:active, a:visited { color: white; }</STYLE></HEAD><BODY><BR><BR><H1><CENTER>$2</CENTER></H1></BODY></HTML>"

  LENGTH="${#HTML}"
  TMP_FILE=$(mktemp -q /tmp/server.XXXXXX)

  echo -en "HTTP/1.1 200 OK\nContent-Length: ${LENGTH}\nConnection: close\n\n$HTML" > "$TMP_FILE"
  socat TCP4-LISTEN:"${1:-5000}",reuseaddr,fork,crlf SYSTEM:"cat ${TMP_FILE}" 2> /dev/null & wait $!

fi
