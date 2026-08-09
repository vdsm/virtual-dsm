#!/usr/bin/env bash
set -Eeuo pipefail

if enabled "$DEBUG"; then
  echo
  printf "QEMU arguments:\n\n    %s\n\n" "${ARGS// -/$'\n    -'}"
fi

# Must always remain the very last command
enableTrap

return 0
