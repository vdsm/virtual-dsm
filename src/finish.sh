#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$DEBUG" == [Yy1]* ]]; then
  printf "QEMU arguments:\n\n%s\n\n" "${ARGS// -/$'\n-'}"
fi

return 0
