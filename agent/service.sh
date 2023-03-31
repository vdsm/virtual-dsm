#!/bin/bash

PIDFILE="/var/run/agent.pid"
LOGFILE="/var/log/agent.log"
SCRIPT="/usr/local/bin/agent.sh" 

status() {
  if [ -f "$PIDFILE" ]; then
    echo 'Service running' >&2
    return 1
  fi
}

start() {
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")"; then
    echo 'Service already running' >&2
    return 1
  fi
  printf 'Starting agent service...' >&2
  "$SCRIPT" &> "$LOGFILE" & echo $! > "$PIDFILE"
}

stop() {
  if [ ! -f "$PIDFILE" ] || ! kill -0 "$(cat "$PIDFILE")"; then
    echo 'Service not running' >&2
    return 1
  fi
  echo 'Stopping agent service' >&2
  kill -15 "$(cat "$PIDFILE")" && rm -f "$PIDFILE"
  echo 'Service stopped' >&2
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
