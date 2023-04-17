#!/bin/bash

PIDFILE="/var/run/agent.pid"
SCRIPT="/usr/local/bin/agent.sh"

status() {
  if [ -f "$PIDFILE" ]; then
    echo 'Service running'
    exit 1
  fi
}

start() {
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")"; then
    echo 'Service already running'
    exit 1
  fi
  echo 'Starting agent service...'
  chmod 666 /dev/ttyS0
  "$SCRIPT" &> /dev/ttyS0 & echo $! > "$PIDFILE"
  exit 0
}

stop() {
  if [ ! -f "$PIDFILE" ] || ! kill -0 "$(cat "$PIDFILE")"; then
    echo 'Service not running'
    exit 1
  fi
  echo 'Stopping agent service...'
  chmod 666 /dev/ttyS0
  echo 'Stopping agent service...' > /dev/ttyS0
  kill -15 "$(cat "$PIDFILE")" && rm -f "$PIDFILE"
  echo 'Service stopped'
  exit 0
}

case "$1" in
  start)
    start
    ;;
  stop)
    stop
    ;;
  status)
    status
    ;;
  restart)
    stop
    start
    ;;
  *)
    echo "Usage: $0 {start|stop|restart}"
esac
