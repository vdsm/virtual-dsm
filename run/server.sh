#!/usr/bin/env bash
set -eu

trap 'pkill -f nc || true' EXIT
trap exit SIGINT SIGTERM

if [ "$2" != "ipinfo" ]; then

  # Serve the page
  HTML="<!DOCTYPE html><HTML><HEAD><TITLE>VirtualDSM</TITLE><STYLE>body { color: white; background-color: #125bdb; font-family: Verdana,\
        Arial,sans-serif; } a, a:hover, a:active, a:visited { color: white; }</STYLE></HEAD><BODY><BR><BR><H1><CENTER>$2</CENTER></H1></BODY></HTML>"

  LENGTH="${#HTML}"
  RESPONSE="HTTP/1.1 200 OK\nContent-Length: ${LENGTH}\nConnection: close\n\n$HTML\n\n"

  while true; do
    echo -en "$RESPONSE" | nc -lp "${1:-5000}" >/dev/null 2>&1 & wait $!
  done

  exit 0

fi

SH_SCRIPT="/tmp/ipinfo.sh"

{ echo "#!/bin/bash"
  echo "INFO=\$(curl -s -m 5 -S http://127.0.0.1:2210/read?command=10 2>/dev/null)"
  echo "rest=\${INFO#*http_port}"
  echo "rest=\${rest#*:}"
  echo "rest=\${rest%%,*}"
  echo "PORT=\${rest%%\\\"*}"
  echo "rest=\${INFO#*eth0}"
  echo "rest=\${rest#*ip}"
  echo "rest=\${rest#*:}"
  echo "rest=\${rest#*\\\"}"
  echo "IP=\${rest%%\\\"*}"
  echo "BODY=\"The location of DSM is <a href=\"http://\${IP}:\${PORT}\">http://\${IP}:\${PORT}</a><script>\\"
  echo "setTimeout(function(){ window.location.assign('http://\${IP}:\${PORT}'); }, 3000);</script>\""
  echo "HTML=\"<!DOCTYPE html><HTML><HEAD><TITLE>VirtualDSM</TITLE><STYLE>body { color: white; background-color: #125bdb; font-family: Verdana,\\"
  echo "Arial,sans-serif; } a, a:hover, a:active, a:visited { color: white; }</STYLE></HEAD><BODY><BR><BR><H1><CENTER>\$BODY</CENTER></H1></BODY></HTML>\""
  echo "LENGTH=\"\${#HTML}\""
  echo "RESPONSE=\"HTTP/1.1 200 OK\\nContent-Length: \${LENGTH}\\nConnection: close\\n\\n\$HTML\\n\\n\""
  echo "echo -e \"\$RESPONSE\""
} > "$SH_SCRIPT"

chmod +x "$SH_SCRIPT"

while true ; do
  nc -lp "${1:-5000}" -e "$SH_SCRIPT" >/dev/null 2>&1 & wait $!
done
