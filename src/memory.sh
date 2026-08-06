#!/usr/bin/env bash
set -Eeuo pipefail

msg="Checking memory..."
enabled "$DEBUG" && echo "$msg"

RAM_WARNING=""
RAM_ALLOCATION=""

checkConfiguredMemory() {

  if disabled "$RAM_CHECK" || [[ "${RAM_SIZE,,}" == "max" || "${RAM_SIZE,,}" == "half" ]]; then
    return 0
  fi

  local wanted avail_mem
  wanted=$(numfmt --from=iec "$RAM_SIZE")
  avail_mem=$(formatBytes "$RAM_AVAIL")

  if (( (wanted + RAM_SPARE) > RAM_AVAIL )); then

    local msg="Your configured RAM_SIZE of ${RAM_SIZE/G/ GB} is too high for the $avail_mem of free memory available,"

    # ZFS ARC can release cached memory under pressure, so this free-memory
    # heuristic remains informational instead of rewriting RAM_SIZE.
    if [[ "${FS,,}" == "zfs" ]]; then

      info "$msg but since ZFS is active this will be ignored."

    else

      RAM_SIZE="max"
      RAM_WARNING="$msg it will automatically be adjusted to a lower amount."

    fi

  else

    if (( (wanted + (RAM_SPARE * 3)) > RAM_AVAIL )); then

      local msg="your configured RAM_SIZE of ${RAM_SIZE/G/ GB} is very close to the $avail_mem of free memory available,"

      if [[ "${FS,,}" == "zfs" ]]; then
        info "$msg but since ZFS is active this will be ignored."
      else
        warn "$msg please consider a lower amount."
      fi

    fi

  fi

  return 0
}

configureHalfMemory() {

  if [[ "${RAM_SIZE,,}" != "half" ]]; then
    return 0
  fi

  if (( (RAM_AVAIL / 2) > RAM_SPARE )); then

    local wanted=$(( RAM_AVAIL / 2 ))

    # Divide by one byte more than a MiB to round down
    local target=$(( wanted / 1048577 ))
    RAM_SIZE="${target}M"
    RAM_ALLOCATION="$wanted"

  else

    RAM_SIZE="max"

  fi

  return 0
}

configureMaxMemory() {

  if [[ "${RAM_SIZE,,}" != "max" ]]; then
    return 0
  fi

  # max keeps a host reserve when possible, but on very small systems falls back
  # to half the available memory to avoid starving the container.
  if (( RAM_AVAIL < (RAM_SPARE * 2) )); then

    local wanted=$(( RAM_AVAIL / 2 ))

  else

    local wanted=$(( RAM_AVAIL - (RAM_SPARE * 3) ))

    if (( wanted < (RAM_SPARE * 6) )); then
      wanted=$(( RAM_AVAIL - RAM_SPARE ))
    fi

  fi

  # Divide by one byte more than a MiB to round down
  local target=$(( wanted / 1048577 ))
  RAM_SIZE="${target}M"
  RAM_ALLOCATION="$wanted"

  return 0
}

checkMinimumMemory() {

  local wanted
  wanted=$(numfmt --from=iec "$RAM_SIZE")

  if [ "$wanted" -lt "$RAM_MINIMUM" ]; then

    error "$(app) requires at least $(formatBytes "$RAM_MINIMUM") of RAM, but only $(formatBytes "$wanted") can be allocated."
    echo
    showMemoryLimitHint

    exit 16
  fi

  return 0
}

getMemoryInfo

checkConfiguredMemory
configureHalfMemory
configureMaxMemory
checkMinimumMemory

[ -n "$RAM_WARNING" ] && warn "$RAM_WARNING"
[ -n "$RAM_ALLOCATION" ] && info "Allocated $(formatBytes "$RAM_ALLOCATION") of RAM for $(app)."

return 0
