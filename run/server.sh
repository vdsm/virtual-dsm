#!/usr/bin/env bash
set -eu

TMP_FILE=$(mktemp -q /tmp/server.XXXXXX)

stop() {
  trap - SIGINT EXIT
  { pkill -f socat || true; } 2>/dev/null
  [ -f "$TMP_FILE" ] && rm -f "$TMP_FILE"
}

trap 'stop' EXIT SIGINT SIGTERM SIGHUP

html()
{
    local h="<!DOCTYPE html><HTML><HEAD><TITLE>VirtualDSM</TITLE>"
    h="${h} <STYLE>body { color: white; background-color: #125bdb; font-family: Verdana,"
    h="${h} Arial,sans-serif; } a, a:hover, a:active, a:visited { color: white; }</STYLE></HEAD>"
    h="${h}<BODY><BR><BR><H1><CENTER>$1</CENTER></H1></BODY></HTML>"

    echo "$h"
}

if [[ "$2" != "/"* ]]; then

  BODY="$2"

  if [[ "$BODY" == "install" ]]; then
    BODY="Please wait while Virtual DSM is being installed..."
    BODY="$BODY<script>setTimeout(() => { document.location.reload(); }, 9999);</script>"
  fi

  HTML=$(html "$BODY")
  printf '%b' "HTTP/1.1 200 OK\nContent-Length: ${#HTML}\nConnection: close\n\n$HTML" > "$TMP_FILE"

  socat TCP4-LISTEN:80,reuseaddr,fork,crlf SYSTEM:"cat ${TMP_FILE}" 2> /dev/null &
  socat TCP4-LISTEN:"${1:-5000}",reuseaddr,fork,crlf SYSTEM:"cat ${TMP_FILE}" 2> /dev/null & wait $!
  
  exit
  
fi

if [[ "$2" != "/run/ip.sh" ]]; then

  cp "$2" "$TMP_FILE"

else

  BODY="The location of DSM is <a href='http://\${IP}:\${PORT}'>http://\${IP}:\${PORT}</a><script>"
  BODY="${BODY}setTimeout(function(){ window.location.assign('http://\${IP}:\${PORT}'); }, 3000);</script>"
  WAIT="Please wait while discovering IP...<script>setTimeout(() => { document.location.reload(); }, 4999);</script>"

  HTML=$(html "xxx")

  { echo "#!/bin/bash"
    echo "INFO=\$(curl -s -m 2 -S http://127.0.0.1:2210/read?command=10 2>/dev/null)"
    echo "rest=\${INFO#*http_port}; rest=\${rest#*:}; rest=\${rest%%,*}; PORT=\${rest%%\\\"*}"
    echo "rest=\${INFO#*eth0}; rest=\${rest#*ip}; rest=\${rest#*:}; rest=\${rest#*\\\"}; IP=\${rest%%\\\"*}"
    echo "HTML=\"$HTML\"; [ -z \"\${IP}\" ] && BODY=\"$WAIT\" || BODY=\"$BODY\"; HTML=\${HTML/xxx/\$BODY}"
    echo "printf '%b' \"HTTP/1.1 200 OK\\nContent-Length: \${#HTML}\\nConnection: close\\n\\n\$HTML\""
  } > "$TMP_FILE"

fi

chmod +x "$TMP_FILE"
  
socat TCP4-LISTEN:80,reuseaddr,fork,crlf SYSTEM:"$TMP_FILE" 2> /dev/null &
socat TCP4-LISTEN:"${1:-5000}",reuseaddr,fork,crlf SYSTEM:"$TMP_FILE" 2> /dev/null & wait $!
