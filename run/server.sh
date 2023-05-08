#!/usr/bin/env bash
set -eu

TMP_FILE=$(mktemp -q /tmp/server.XXXXXX)

stop() {
  trap - SIGINT EXIT
  { pkill -f socat || true; } 2>/dev/null
  [ -f "$TMP_FILE" ] && rm -f "$TMP_FILE"
}

trap 'stop' EXIT SIGINT SIGTERM SIGHUP

if [[ "$2" == "/"* ]]; then

  if [[ "$2" == "/run/ip.sh" ]]; then

    { echo "#!/bin/bash"
      echo "INFO=\$(curl -s -m 5 -S http://127.0.0.1:2210/read?command=10 2>/dev/null)"
      echo "rest=\${INFO#*http_port}; rest=\${rest#*:}; rest=\${rest%%,*}; PORT=\${rest%%\\\"*}"
      echo "rest=\${INFO#*eth0}; rest=\${rest#*ip}; rest=\${rest#*:}; rest=\${rest#*\\\"}; IP=\${rest%%\\\"*}"
      echo "BODY=\"The location of DSM is <a href=\"http://\${IP}:\${PORT}\">http://\${IP}:\${PORT}</a><script>\\"
      echo "setTimeout(function(){ window.location.assign('http://\${IP}:\${PORT}'); }, 3000);</script>\""
      echo "HTML=\"<!DOCTYPE html><HTML><HEAD><TITLE>VirtualDSM</TITLE><STYLE>body { color: white; background-color: #125bdb; font-family: Verdana,\\"
      echo "Arial,sans-serif; } a, a:hover, a:active, a:visited { color: white; }</STYLE></HEAD><BODY><BR><BR><H1><CENTER>\$BODY</CENTER></H1></BODY></HTML>\""
      echo "echo -e \"\HTTP/1.1 200 OK\\nContent-Length: \${#HTML}\\nConnection: close\\n\\n\$HTML\""
    } > "$TMP_FILE"

  else

      cp "$2" "$TMP_FILE"

  fi

  chmod +x "$TMP_FILE"
  socat TCP4-LISTEN:"${1:-5000}",reuseaddr,fork,crlf SYSTEM:"$TMP_FILE" 2> /dev/null & wait $!

else

  HTML="<!DOCTYPE html><HTML><HEAD><TITLE>VirtualDSM</TITLE><STYLE>body { color: white; background-color: #125bdb; font-family: Verdana,\
        Arial,sans-serif; } a, a:hover, a:active, a:visited { color: white; }</STYLE></HEAD><BODY><BR><BR><H1><CENTER>$2</CENTER></H1></BODY></HTML>"

  echo -en "HTTP/1.1 200 OK\nContent-Length: ${#HTML}\nConnection: close\n\n$HTML" > "$TMP_FILE"
  socat TCP4-LISTEN:"${1:-5000}",reuseaddr,fork,crlf SYSTEM:"cat ${TMP_FILE}" 2> /dev/null & wait $!

fi
