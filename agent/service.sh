#!/bin/bash

PIDFILE="/var/run/agent.pid"
SCRIPT="/usr/local/bin/agent.sh"

status() {
  if [ -f "$PIDFILE" ]; then
    echo 'Service running'
    return 1
  fi
  return 0
}

start() {
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")"; then
    echo 'Service already running'
    return 1
  fi
  echo 'Starting agent service...'
  chmod 666 /dev/ttyS0
  "$SCRIPT" &> /dev/ttyS0 & echo $! > "$PIDFILE"
  return 0
}

stop() {
  if [ ! -f "$PIDFILE" ] || ! kill -0 "$(cat "$PIDFILE")"; then
    echo 'Service not running'
    return 1
  fi
  echo 'Stopping agent service...'
  chmod 666 /dev/ttyS0
  echo 'Stopping agent service...' > /dev/ttyS0
  kill -15 "$(cat "$PIDFILE")" && rm -f "$PIDFILE"
  echo 'Service stopped'
  return 0
}

ret=0

case "$1" in
  start)
    ret=start
    ;;
  stop)
    ret=stop
    ;;
  status)
    ret=status
    ;;
  restart)
    stop
    ret=start
    ;;
  *)
    echo "Usage: $0 {start|stop|restart}"
    ret=1
esac

exit ret
