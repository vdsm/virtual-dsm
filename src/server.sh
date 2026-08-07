#!/usr/bin/env bash
set -Eeuo pipefail

: "${WEB_PORT:="5000"}"    # Webserver port

# Sanitize port variables
WEB_PORT=$(strip "$WEB_PORT")

WEB_PID="/run/nginx.pid"
WSD_LOG="/var/log/websocketd.log"
WSD_PID="$QEMU_DIR/websocketd.pid"
WSD_SOCKET="$QEMU_DIR/status-ws.sock"

prepareWebFiles() {

  cp -r /var/www/* "$QEMU_DIR" || return 1
  rm -f -- "$WSD_PID" "$WSD_SOCKET" "$WEB_PID" "$WSD_LOG" || return 1

  return 0
}

configureWebPorts() {

  if ! sed -i \
    -e "s|listen 5000 default_server;|listen $WEB_PORT default_server;|g" \
    /etc/nginx/sites-enabled/web.conf; then
    error "Failed to configure webserver port!"
    return 1
  fi

  return 0
}

configureIpv6Listen() {

  # Use one dual-stack listener when IPv6 is active, avoiding separate IPv4
  # and IPv6 sockets that can conflict on the same port.
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

configureNginx() {

  mkdir -p /etc/nginx/sites-enabled || return 1
  rm -f /etc/nginx/sites-enabled/default || return 1

  if ! sed -i \
    -e 's/^worker_processes.*/worker_processes 1;/' \
    /etc/nginx/nginx.conf; then
    error "Failed to configure nginx!"
    return 1
  fi

  cp /etc/nginx/default.conf /etc/nginx/sites-enabled/web.conf

  return 0
}

configureWebServer() {

  configureNginx || return 1
  configureWebPorts || return 1
  configureIpv6Listen || return 1

  return 0
}

stopWebServer() {

  local pid

  if readPidFile pid "$WEB_PID"; then
    pKill "$pid" 2

    # Escalate only after the normal termination grace period; stale nginx
    # processes would otherwise keep the configured web port occupied.
    if isAlive "$pid"; then
      kill -9 -- "$pid" 2>/dev/null || :
    fi
  fi

  rm -f -- "$WEB_PID"
  return 0
}

startWebServer() {

  # Start webserver
  nginx -e stderr || return 1

  return 0
}

stopWebsocketServer() {

  local pid

  if readPidFile pid "$WSD_PID"; then
    pKill "$pid" 2

    if isAlive "$pid"; then
      kill -9 -- "$pid" 2>/dev/null || :
    fi
  fi

  rm -f -- "$WSD_PID" "$WSD_SOCKET"
  return 0
}

startWebsocketServer() {

  # Start websocket server
  websocketd \
    --unixsocket="$WSD_SOCKET" \
    /run/socket.sh \
    >"$WSD_LOG" 2>&1 &

  local pid=$!

  if ! echo "$pid" > "$WSD_PID"; then
    kill "$pid" 2>/dev/null || :
    rm -f -- "$WSD_PID"
    return 1
  fi

  # Keep the sidecar alive briefly before accepting startup as successful,
  # surfacing immediate bind or script failures with its captured log.
  local i
  for (( i = 1; i <= 5; i++ )); do

    if ! isAlive "$pid"; then
      rm -f -- "$WSD_PID"
      [ -s "$WSD_LOG" ] && cat "$WSD_LOG" >&2
      error "Failed to start websocket server!"
      return 1
    fi

    sleep 0.1

  done

  return 0
}

prepareWebFiles

html "Starting $APP for $ENGINE..."

disabled "${WEB:-}" && return 0

configureWebServer

if startWebServer && startWebsocketServer; then
  return 0
fi

stopWebsocketServer || :
stopWebServer || :

return 1
