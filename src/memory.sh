#!/usr/bin/env bash
set -Eeuo pipefail

msg="Checking memory..."
enabled "$DEBUG" && echo "$msg"

RAM_AVAIL=$(free -b | grep -m 1 Mem: | awk '{print $7}')
AVAIL_MEM=$(formatBytes "$RAM_AVAIL")

checkConfiguredMemory() {
  local wanted msg

  if disabled "$RAM_CHECK" || [[ "${RAM_SIZE,,}" == "max" || "${RAM_SIZE,,}" == "half" ]]; then
    return 0
  fi

  wanted=$(numfmt --from=iec "$RAM_SIZE")

  if (( (wanted + RAM_SPARE) > RAM_AVAIL )); then
    msg="Your configured RAM_SIZE of ${RAM_SIZE/G/ GB} is too high for the $AVAIL_MEM of free memory available,"
    if [[ "${FS,,}" == "zfs" ]]; then
      info "$msg but since ZFS is active this will be ignored."
    else
      RAM_SIZE="max"
      warn "$msg it will automatically be adjusted to a lower amount."
    fi
  else
    if (( (wanted + (RAM_SPARE * 3)) > RAM_AVAIL )); then
      msg="your configured RAM_SIZE of ${RAM_SIZE/G/ GB} is very close to the $AVAIL_MEM of free memory available,"
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
  local wanted

  if [[ "${RAM_SIZE,,}" != "half" ]]; then
    return 0
  fi

  if (( (RAM_AVAIL / 2) > RAM_SPARE )); then
    wanted=$(( (RAM_AVAIL / 2) / 1048577 ))
    RAM_SIZE="${wanted}M"
    info "Allocated $wanted MB of RAM for the virtual machine."
  else
    RAM_SIZE="max"
  fi

  return 0
}

configureMaxMemory() {
  local wanted

  if [[ "${RAM_SIZE,,}" != "max" ]]; then
    return 0
  fi

  if (( RAM_AVAIL < (RAM_SPARE * 2) )); then

    wanted=$(( RAM_AVAIL / 2 ))

  else

    wanted=$(( RAM_AVAIL - (RAM_SPARE * 3) ))

    if (( wanted < (RAM_SPARE * 6) )); then
      wanted=$(( RAM_AVAIL - RAM_SPARE ))
    fi

  fi

  wanted=$(( wanted / 1048577 ))
  RAM_SIZE="${wanted}M"

  info "Allocated $wanted MB of RAM for the virtual machine."

  return 0
}

checkMinimumMemory() {
  local wanted

  wanted=$(numfmt --from=iec "$RAM_SIZE")

  if [ "$wanted" -lt "$RAM_MINIMUM" ]; then
    wanted=$(( wanted / 1048577 ))
    error "Not enough memory available, there is only $wanted MB left!"
    exit 16
  fi

  return 0
}

checkConfiguredMemory
configureHalfMemory
configureMaxMemory
checkMinimumMemory

return 0
