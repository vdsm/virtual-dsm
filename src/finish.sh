#!/usr/bin/env bash
set -Eeuo pipefail

if enabled "$DEBUG"; then
  printf "QEMU arguments:\n\n%s\n\n" "${ARGS// -/$'\n-'}"
fi

return 0
