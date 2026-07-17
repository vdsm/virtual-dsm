#!/usr/bin/env bash
set -Eeuo pipefail

: "${PLATFORM:="x64"}"
: "${APP:="Virtual DSM"}"
: "${SUPPORT:="https://github.com/vdsm/virtual-dsm"}"

cd /run

. start.sh      # Startup hook
. utils.sh      # Load functions
. reset.sh      # Initialize system
. server.sh     # Start webserver
. install.sh    # Run installation
. disk.sh       # Initialize disks
. display.sh    # Initialize graphics
. network.sh    # Initialize network
. proc.sh       # Initialize processor
. serial.sh     # Initialize serialport
. power.sh      # Configure shutdown
. memory.sh     # Check available memory
. config.sh     # Configure arguments
. finish.sh     # Finish initialization

trap - ERR

: "${CONSOLE_SOCKET:="$QEMU_DIR/console.sock"}"

CONSOLE_PID=""
TTY_STATE=""

cleanupConsole() {

  local rc=$?

  trap - EXIT

  if [ -n "$CONSOLE_PID" ]; then
    kill "$CONSOLE_PID" 2>/dev/null || true
    wait "$CONSOLE_PID" 2>/dev/null || true
  fi

  if [ -n "$TTY_STATE" ] && [ -c /dev/tty ]; then
    stty "$TTY_STATE" </dev/tty 2>/dev/null || true
  fi

  rm -f "$CONSOLE_SOCKET"

  exit "$rc"
}

startConsole() {

  local cnt=0

  rm -f "$CONSOLE_SOCKET"

  if [ -t 1 ] && [ -c /dev/tty ]; then

    if ! TTY_STATE=$(stty -g </dev/tty); then
      error "Failed to read terminal settings!"
      return 1
    fi

    # Use character-at-a-time input without local echo. Keep ISIG enabled
    # so Ctrl+C reaches entry.sh, and disable XON/XOFF flow control.
    if ! stty -icanon -echo isig -ixon min 1 time 0 </dev/tty; then
      error "Failed to configure DSM console terminal!"
      return 1
    fi

    (
      # entry.sh handles these signals. Keep the console relay alive while
      # the graceful shutdown procedure is running.
      trap '' INT QUIT
      exec nc -lU "$CONSOLE_SOCKET" </dev/tty
    ) &

  else

    nc -lU "$CONSOLE_SOCKET" </dev/null &

  fi

  CONSOLE_PID=$!

  while [ ! -S "$CONSOLE_SOCKET" ]; do

    if ! kill -0 "$CONSOLE_PID" 2>/dev/null; then
      error "DSM console relay exited unexpectedly!"
      return 1
    fi

    sleep 0.02
    cnt=$((cnt + 1))

    if (( cnt > 100 )); then
      error "Failed to start DSM console relay!"
      return 1
    fi

  done

  return 0
}

trap cleanupConsole EXIT

cmd=(qemu-system-x86_64)
version=$("${cmd[@]}" --version | awk 'NR==1 { print $4 }')
info "Booting $APP using QEMU v$version..." && echo

startConsole

if enabled "$SHUTDOWN"; then

  # Isolate QEMU from terminal-generated signals. Ctrl+C reaches entry.sh,
  # which performs the graceful shutdown through power.sh.
  setsid -w "${cmd[@]}" ${ARGS:+ $ARGS} </dev/null &

else

  # Preserve the old behavior when graceful shutdown is disabled:
  # Ctrl+C reaches both entry.sh and QEMU and terminates the container.
  "${cmd[@]}" ${ARGS:+ $ARGS} </dev/null &

fi

qemu_job=$!

rc=0
wait "$qemu_job" || rc=$?
[ -f "$QEMU_END" ] && exit "$rc"

sleep 1 & wait $!
finish "$rc"
