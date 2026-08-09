#!/usr/bin/env bash
set -Eeuo pipefail

normalizeMemory() {

  local name="${1:-$(app)}"

  RAM_SPARE=500000000
  RAM_MINIMUM="${RAM_MINIMUM:-136314880}"

  RAM_MINIMUM=$(strip "$RAM_MINIMUM")
  RAM_MINIMUM="${RAM_MINIMUM// /}"
  RAM_MINIMUM=$(echo "${RAM_MINIMUM^^}" | sed 's/MB/M/g;s/GB/G/g;s/TB/T/g')
  numfmt --from=iec "$RAM_MINIMUM" &>/dev/null || {
    error "Invalid RAM_MINIMUM: $RAM_MINIMUM"
    exit 16
  }
  RAM_MINIMUM=$(numfmt --from=iec "$RAM_MINIMUM")

  RAM_SIZE=$(strip "$RAM_SIZE")
  RAM_SIZE="${RAM_SIZE// /}"
  [ -z "$RAM_SIZE" ] && RAM_SIZE="2G"

  if [[ "${RAM_SIZE,,}" != "max" && "${RAM_SIZE,,}" != "half" ]]; then

    # Bare values below 130 are interpreted as GiB for convenience; larger bare
    # values are treated as MiB to preserve historical configurations.
    if [ -z "${RAM_SIZE//[0-9. ]}" ]; then
      [ "${RAM_SIZE%%.*}" -lt "130" ] && RAM_SIZE="${RAM_SIZE}G" || RAM_SIZE="${RAM_SIZE}M"
    fi

    RAM_SIZE=$(echo "${RAM_SIZE^^}" | sed 's/MB/M/g;s/GB/G/g;s/TB/T/g')
    numfmt --from=iec "$RAM_SIZE" &>/dev/null || {
      error "Invalid RAM_SIZE: $RAM_SIZE"
      exit 16
    }

    local wanted
    wanted=$(numfmt --from=iec "$RAM_SIZE")

    if [ "$wanted" -lt "$RAM_MINIMUM" ]; then
      error "$name requires at least $(formatBytes "$RAM_MINIMUM") of RAM, but RAM_SIZE is set to $(formatBytes "$wanted")."
      exit 16
    fi

    # QEMU requires a whole-number memory value, so convert decimal sizes to MiB.
    if [[ "$RAM_SIZE" == *.* ]]; then
      RAM_SIZE="$(( wanted / 1048576 ))M"
    fi

  fi

  return 0
}

checkConfiguredMemory() {

  local final="$1"

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

      enabled "$final" && info "$msg but since ZFS is active this will be ignored."

    else

      RAM_SIZE="max"
      RAM_WARNING="$msg it will automatically be adjusted to a lower amount."

    fi

  else

    if (( (wanted + (RAM_SPARE * 3)) > RAM_AVAIL )); then

      local msg="your configured RAM_SIZE of ${RAM_SIZE/G/ GB} is very close to the $avail_mem of free memory available,"

      if [[ "${FS,,}" == "zfs" ]]; then
        enabled "$final" && info "$msg but since ZFS is active this will be ignored."
      else
        enabled "$final" && warn "$msg please consider a lower amount."
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

showMemoryLimitHint() {

  local kernel
  kernel=$(uname -r)

  if [[ "${kernel,,}" == *-wsl2* ]]; then
    echo
    info "Docker Desktop (WSL2) is detected, follow these instructions:"
    info ""
    info "Increase the memory limit in \"%UserProfile%\\.wslconfig\" by setting \"memory=<size>\" under \"[wsl2]\"."
    info "Then run \"wsl --shutdown\" in PowerShell and restart Docker Desktop for the new limit to take effect."
    echo
  fi

  return 0
}

checkMinimumMemory() {

  local name="${1:-$(app)}"
  local wanted
  wanted=$(numfmt --from=iec "$RAM_SIZE")

  if [ "$wanted" -lt "$RAM_MINIMUM" ]; then

    error "$name requires at least $(formatBytes "$RAM_MINIMUM") of RAM, but only $(formatBytes "$wanted") can be allocated."

    showMemoryLimitHint

    exit 16
  fi

  return 0
}

checkMemoryAllocation() {

  local final="${1:-N}"
  local name="${2:-${RAM_NAME:-$(app)}}"
  local configured

  normalizeMemory "$name"
  configured="$RAM_SIZE"

  RAM_WARNING=""
  RAM_ALLOCATION=""

  getMemoryInfo
  checkConfiguredMemory "$final"

  configureHalfMemory
  configureMaxMemory
  checkMinimumMemory "$name"

  if enabled "$final"; then
    [ -n "$RAM_WARNING" ] && warn "$RAM_WARNING"
    [ -n "$RAM_ALLOCATION" ] && info "Allocated $(formatBytes "$RAM_ALLOCATION") of RAM for $(app)."
  else
    RAM_SIZE="$configured"
  fi

  return 0
}

checkMemoryRequirement() {

  local name="${1:-$(app)}"

  # Retain the description so the final check uses the same error message.
  RAM_NAME="$name"

  checkMemoryAllocation "N" "$name"

  return 0
}

finalizeMemory() {

  checkMemoryAllocation "Y" "${RAM_NAME:-$(app)}"

  return 0
}

checkMemoryRequirement

return 0
