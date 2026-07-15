#!/usr/bin/env bash
set -Eeuo pipefail

: "${COM_PORT:="2210"}"    # Comm port
: "${WEB_PORT:="5000"}"    # Webserver port
: "${CHR_PORT:="12345"}"   # Character port
: "${WSD_PORT:="8004"}"    # Websockets port

# Sanitize port variables
COM_PORT=$(strip "$COM_PORT")
WEB_PORT=$(strip "$WEB_PORT")
CHR_PORT=$(strip "$CHR_PORT")
WSD_PORT=$(strip "$WSD_PORT")

WEB_PID="/run/nginx.pid"
WSD_PID="$QEMU_DIR/websocketd.pid"

prepareWebFiles() {

  cp -r /var/www/* "$QEMU_DIR" || return 1
  rm -f "$WSD_PID" "$WEB_PID" || return 1

  return 0
}

configureWebPorts() {

  sed -i "s/listen 5000 default_server;/listen $WEB_PORT default_server;/g" /etc/nginx/sites-enabled/web.conf
  sed -i "s/proxy_pass http:\/\/127.0.0.1:8004\/;/proxy_pass http:\/\/127.0.0.1:$WSD_PORT\/;/g" /etc/nginx/sites-enabled/web.conf

  return 0
}

configureIpv6Listen() {

  # shellcheck disable=SC2143
  if [ -f /proc/net/if_inet6 ] && [[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" != "1" ]] && [ -n "$(ifconfig -a | grep inet6)" ]; then
    sed -i "s/listen $WEB_PORT default_server;/listen [::]:$WEB_PORT default_server ipv6only=off;/g" /etc/nginx/sites-enabled/web.conf
  fi

  return 0
}

configureWebServer() {

  mkdir -p /etc/nginx/sites-enabled
  cp /etc/nginx/default.conf /etc/nginx/sites-enabled/web.conf

  configureWebPorts
  configureIpv6Listen

  return 0
}

startWebServer() {

  # Start webserver
  nginx -e stderr
}

startWebsocketServer() {

  local log="/var/log/websocketd.log"
  rm -f "$log"

  # Start websocket server
  websocketd --address 127.0.0.1 --port="$WSD_PORT" /run/socket.sh > "$log" 2>&1 &
  local pid=$!

  if ! echo "$pid" > "$WSD_PID"; then
    kill "$pid" 2>/dev/null || :
    return 1
  fi

  sleep 0.1

  if ! isAlive "$pid"; then
    rm -f "$WSD_PID"
    [ -s "$log" ] && cat "$log" >&2
    error "Failed to start websocket server!"
    return 1
  fi

  return 0
}

prepareWebFiles || return 1

html "Starting $APP for $ENGINE..."

disabled "${WEB:-}" && return 0

configureWebServer || return 1

startWebServer || return 1
startWebsocketServer || return 1

return 0
