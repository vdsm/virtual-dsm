#!/usr/bin/env bash
set -Eeuo pipefail

addSystemDisks() {

  local boot="$STORAGE/$BASE.boot.img"
  local system="$STORAGE/$BASE.system.img"

  [ ! -s "$boot" ] && error "Virtual DSM boot-image does not exist ($boot)" && return 81
  [ ! -s "$system" ] && error "Virtual DSM system-image does not exist ($system)" && return 82

  setOwner "$boot" || warn "failed to set the owner for \"$boot\" !"
  setOwner "$system" || warn "failed to set the owner for \"$system\" !"

  DISK_OPTS+=$(createDevice "$boot" "$DISK_TYPE" "1" "0xa" "raw" "$DISK_IO" "$DISK_CACHE" "" "" "synoboot")
  DISK_OPTS+=$(createDevice "$system" "$DISK_TYPE" "2" "0xb" "raw" "$DISK_IO" "$DISK_CACHE" "" "" "synosys")

  return 0
}

closeWebserver() {

  disabled "${NETWORK:-Y}" && return 0

  MSG="Booting DSM instance..."
  html "$MSG" || return $?

  if enabled "${DHCP:-N}" || disabled "${WEB:-}"; then
    return 0
  fi

  writeAtomic "$WSD_COMMAND" "portal" || return $?

  sleep 1.2
  stopAllServers

  WEB="N"

  return 0
}

addSystemDisks || return $?
closeWebserver || return $?

return 0
