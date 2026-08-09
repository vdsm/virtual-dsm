#!/usr/bin/env bash
set -Eeuo pipefail

: "${VNC_PORT:="5900"}"    # VNC port
: "${WEB_PORT:="8006"}"    # Webserver port

# Sanitize port variables
VNC_PORT=$(strip "$VNC_PORT")
WEB_PORT=$(strip "$WEB_PORT")

WEB_PID="/run/nginx.pid"
WSD_PID="$QEMU_DIR/websocketd.pid"
AUX_PID="$QEMU_DIR/audio-websocketd.pid"

WSS_SOCKET="$QEMU_DIR/vnc-ws.sock"
AUX_SOCKET="$QEMU_DIR/audio-ws.sock"
WSD_SOCKET="$QEMU_DIR/status-ws.sock"
WSD_COMMAND="$QEMU_DIR/status.cmd"

WSD_LOG="/var/log/websocketd.log"
AUX_LOG="/var/log/audio-socket.log"

validateVncPort() {

  if (( VNC_PORT < 5900 )); then
    warn "VNC port cannot be set lower than 5900, ignoring value $VNC_PORT."
    VNC_PORT="5900"
  fi

  return 0
}

prepareWebFiles() {

  cp -r /var/www/* "$QEMU_DIR" || return 1
  rm -f -- \
    "$WSD_PID" "$AUX_PID" "$WEB_PID" \
    "$WSD_SOCKET" "$AUX_SOCKET" "$WSD_COMMAND" \
    "$WSD_LOG" "$AUX_LOG" || return 1

  return 0
}

configureAuthentication() {

  if ! enabled "${PROTECT:-}" && [ -z "${PASS:-}" ]; then
    return 0
  fi

  local user="Docker"
  local pass="admin"

  USERNAME=$(strip "${USERNAME:-}")
  [ -n "${USERNAME:-}" ] && user="$USERNAME"
  [ -n "${PASSWORD:-}" ] && pass="$PASSWORD"

  # PASS is the legacy web-password variable and intentionally overrides the
  # newer general PASSWORD value for backwards compatibility.
  [ -n "${PASS:-}" ] && pass="$PASS"

  # Set password
  if ! printf '%s\n' "$user:{PLAIN}$pass" > /etc/nginx/.htpasswd; then
    error "Failed to create web authentication file!"
    return 1
  fi

  if ! sed -i "s/auth_basic off/auth_basic \"NoVNC\"/g" /etc/nginx/sites-enabled/web.conf; then
    error "Failed to enable web authentication!"
    return 1
  fi

  return 0
}

configureWebPorts() {

  if ! sed -i \
    -E "s|listen [0-9]+ default_server;|listen $WEB_PORT default_server;|g" \
    /etc/nginx/sites-enabled/web.conf; then
    error "Failed to configure webserver port!"
    return 1
  fi

  return 0
}

configureIpv6Listen() {

  if [ -f /proc/net/if_inet6 ] && [[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" != "1" ]]; then

    # Use one dual-stack socket when IPv6 is available; ipv6only=off keeps IPv4
    # clients working on the same configured WEB_PORT.
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

  # TODO: Use setfacl to grant www-data access to the Unix sockets
  # and restore unprivileged nginx workers.
  if ! sed -i \
    -e 's/^user .*/user root;/' \
    -e 's/^worker_processes.*/worker_processes 1;/' \
    /etc/nginx/nginx.conf; then
    error "Failed to configure nginx!"
    return 1
  fi

  if ! cp /etc/nginx/default.conf /etc/nginx/sites-enabled/web.conf; then
    error "Failed to copy nginx config!"
    return 1
  fi

  return 0
}

configureWebServer() {

  configureNginx || return 1
  configureAuthentication || return 1
  configureWebPorts || return 1
  configureIpv6Listen || return 1

  return 0
}

stopWebServer() {

  local pid

  if readPidFile pid "$WEB_PID"; then
    pKill "$pid" 2

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

  local i
  for (( i = 1; i <= 50; i++ )); do

    if ! isAlive "$pid"; then
      rm -f -- "$WSD_PID" "$WSD_SOCKET"
      [ -s "$WSD_LOG" ] && cat "$WSD_LOG" >&2
      error "Failed to start websocket server!"
      return 1
    fi

    [ -S "$WSD_SOCKET" ] && return 0

    sleep 0.1

  done

  pKill "$pid" 2

  if isAlive "$pid"; then
    kill -9 -- "$pid" 2>/dev/null || :
  fi

  rm -f -- "$WSD_PID" "$WSD_SOCKET"
  [ -s "$WSD_LOG" ] && cat "$WSD_LOG" >&2
  error "Websocket server did not create its socket!"
  return 1
}

stopAudioServer() {

  local pid

  if readPidFile pid "$AUX_PID"; then
    pKill "$pid" 2

    if isAlive "$pid"; then
      kill -9 -- "$pid" 2>/dev/null || :
    fi
  fi

  rm -f -- "$AUX_PID" "$AUX_SOCKET"
  return 0
}

startAudioServer() {

  # Start audio websocket server
  websocketd \
    --unixsocket="$AUX_SOCKET" \
    --binary=true \
    nc -U "$AUDIO_SOCKET" \
    >"$AUX_LOG" 2>&1 &

  local pid=$!

  if ! echo "$pid" > "$AUX_PID"; then
    kill "$pid" 2>/dev/null || :
    rm -f -- "$AUX_PID"
    return 1
  fi

  local i
  for (( i = 1; i <= 50; i++ )); do

    if ! isAlive "$pid"; then
      rm -f -- "$AUX_PID" "$AUX_SOCKET"
      [ -s "$AUX_LOG" ] && cat "$AUX_LOG" >&2
      error "Failed to start audio websocket server!"
      return 1
    fi

    [ -S "$AUX_SOCKET" ] && return 0

    sleep 0.1

  done

  pKill "$pid" 2

  if isAlive "$pid"; then
    kill -9 -- "$pid" 2>/dev/null || :
  fi

  rm -f -- "$AUX_PID" "$AUX_SOCKET"
  [ -s "$AUX_LOG" ] && cat "$AUX_LOG" >&2
  error "Audio websocket server did not create its socket!"
  return 1
}

validateVncPort
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
