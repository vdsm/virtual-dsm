#!/usr/bin/env bash
set -Eeuo pipefail

: "${WEB_PORT:="5000"}"    # Webserver port
: "${WSD_PORT:="8004"}"    # Websockets port

# Sanitize port variables
WEB_PORT=$(strip "$WEB_PORT")
WSD_PORT=$(strip "$WSD_PORT")

WEB_PID="/run/nginx.pid"
WSD_LOG="/var/log/websocketd.log"
WSD_PID="$QEMU_DIR/websocketd.pid"

prepareWebFiles() {

  cp -r /var/www/* "$QEMU_DIR" || return 1
  rm -f "$WSD_PID" "$WEB_PID" "$WSD_LOG" || return 1

  return 0
}

configureWebPorts() {

  if ! sed -i \
    -e "s|listen 5000 default_server;|listen $WEB_PORT default_server;|g" \
    -e "s|proxy_pass http://127.0.0.1:8004/;|proxy_pass http://127.0.0.1:$WSD_PORT/;|g" \
    /etc/nginx/sites-enabled/web.conf; then
    error "Failed to configure webserver ports!"
    return 1
  fi

  return 0
}

configureIpv6Listen() {

  if [ -f /proc/net/if_inet6 ] && [[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" != "1" ]]; then

    if ! sed -i \
      "s/listen $WEB_PORT default_server;/listen [::]:$WEB_PORT default_server ipv6only=off;/g" \
      /etc/nginx/sites-enabled/web.conf; then
      error "Failed to configure IPv6 webserver listener!"
      return 1
    fi

  fi

  return 0
}

configureWebServer() {

  mkdir -p /etc/nginx/sites-enabled
  cp /etc/nginx/default.conf /etc/nginx/sites-enabled/web.conf

  configureWebPorts || return 1
  configureIpv6Listen || return 1

  return 0
}

startWebServer() {

  # Start webserver
  nginx -e stderr || return 1

  return 0
}

startWebsocketServer() {

  # Start websocket server
  websocketd \
    --address 127.0.0.1 \
    --port="$WSD_PORT" \
    /run/socket.sh \
    >"$WSD_LOG" 2>&1 &

  local pid=$!

  if ! echo "$pid" > "$WSD_PID"; then
    kill "$pid" 2>/dev/null || :
    return 1
  fi

  sleep 0.1

  if ! isAlive "$pid"; then
    rm -f "$WSD_PID"
    [ -s "$WSD_LOG" ] && cat "$WSD_LOG" >&2
    error "Failed to start websocket server!"
    return 1
  fi

  return 0
}

prepareWebFiles

html "Starting $APP for $ENGINE..."

disabled "${WEB:-}" && return 0

configureWebServer

startWebServer
startWebsocketServer

return 0
