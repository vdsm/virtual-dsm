#!/bin/bash

PIDFILE="/var/run/agent.pid"
SCRIPT="/usr/local/bin/agent.sh"

error () { echo -e "\E[1;31m❯ ERROR: $1\E[0m" ; }
info () { echo -e "\E[1;34m❯\E[1;36m $1\E[0m" ; }

status() {

  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")"; then
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

  if [ ! -f "$SCRIPT" ]; then

    URL="https://raw.githubusercontent.com/vdsm/virtual-dsm/master/agent/agent.sh"

    if ! curl -sfk -m 10 -o "${SCRIPT}" "${URL}"; then
      error 'Failed to download agent script.' > /dev/ttyS0
      rm -f "${SCRIPT}"
      return 1
    else
      info 'Agent script was missing?' > /dev/ttyS0
    fi

    chmod 755 "${SCRIPT}"

  fi

  echo "-" > /var/lock/subsys/agent.sh
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
  info 'Stopping agent service...' > /dev/ttyS0

  kill -15 "$(cat "$PIDFILE")" && rm -f "$PIDFILE"
  rm -f /var/lock/subsys/agent.sh

  echo 'Service stopped'
  return 0
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
    exit 1
esac
