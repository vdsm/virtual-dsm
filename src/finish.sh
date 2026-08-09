#!/usr/bin/env bash
set -Eeuo pipefail

if [ -s "$QEMU_DIR/qemu.host" ] && [[ "$(<"$QEMU_DIR/qemu.host")" == "172.17."* ]]; then
  warn "your container IP starts with 172.17.* which will cause conflicts when you install the Container Manager package inside DSM!"
fi

if enabled "$DEBUG"; then
  echo
  printf "QEMU arguments:\n\n    %s\n\n" "${ARGS// -/$'\n    -'}"
fi

# Must always remain the very last command
enableTrap

return 0
