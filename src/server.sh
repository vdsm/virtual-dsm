#!/usr/bin/env bash
set -Eeuo pipefail

: "${COM_PORT:="2210"}"    # Comm port
: "${MON_PORT:="7100"}"    # Monitor port
: "${WEB_PORT:="5000"}"    # Webserver port
: "${CHR_PORT:="12345"}"   # Character port
: "${WSD_PORT:="8004"}"    # Websockets port

cp -r /var/www/* /run/shm
rm -f /var/run/websocketd.pid

html "Starting $APP for $ENGINE..."

if [[ "${WEB:-}" != [Nn]* ]]; then

  mkdir -p /etc/nginx/sites-enabled
  cp /etc/nginx/default.conf /etc/nginx/sites-enabled/web.conf

  sed -i "s/listen 5000 default_server;/listen $WEB_PORT default_server;/g" /etc/nginx/sites-enabled/web.conf
  sed -i "s/proxy_pass http:\/\/127.0.0.1:8004\/;/proxy_pass http:\/\/127.0.0.1:$WSD_PORT\/;/g" /etc/nginx/sites-enabled/web.conf

  # shellcheck disable=SC2143
  if [ -f /proc/net/if_inet6 ] && [ -n "$(ifconfig -a | grep inet6)" ]; then

    sed -i "s/listen $WEB_PORT default_server;/listen [::]:$WEB_PORT default_server ipv6only=off;/g" /etc/nginx/sites-enabled/web.conf

  fi

  # Start webserver
  nginx -e stderr

  # Start websocket server
  websocketd --address 127.0.0.1 --port="$WSD_PORT" /run/socket.sh >/var/log/websocketd.log &
  echo "$!" > /var/run/websocketd.pid

fi

return 0
