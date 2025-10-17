#!/usr/bin/env bash
set -Eeuo pipefail

RAM_AVAIL=$(free -b | grep -m 1 Mem: | awk '{print $7}')

if [[ "$RAM_CHECK" != [Nn]* && "${RAM_SIZE,,}" != "max" && "${RAM_SIZE,,}" != "half" ]]; then

  AVAIL_MEM=$(formatBytes "$RAM_AVAIL")

  if (( (RAM_WANTED + RAM_SPARE) > RAM_AVAIL )); then
    msg="Your configured RAM_SIZE of ${RAM_SIZE/G/ GB} is too high for the $AVAIL_MEM of memory available,"
    if [[ "${FS,,}" == "zfs" ]]; then
      info "$msg but since ZFS is active this will be ignored."
    else
      RAM_SIZE="max"
      warn "$msg it will automatically be adjusted to a lower amount."
    fi
  else
    if (( (RAM_WANTED + (RAM_SPARE * 3)) > RAM_AVAIL )); then
      msg="your configured RAM_SIZE of ${RAM_SIZE/G/ GB} is very close to the $AVAIL_MEM of memory available,"
      if [[ "${FS,,}" == "zfs" ]]; then
        info "$msg but since ZFS is active this will be ignored."
      else
        warn "$msg please consider a lower amount."
      fi
    fi
  fi

fi

if [[ "${RAM_SIZE,,}" == "half" ]]; then

  RAM_WANTED=$(( RAM_AVAIL / 2 ))
  RAM_WANTED=$(( RAM_WANTED / 1073741825 ))

  if (( "$RAM_WANTED" < 1 )); then
    RAM_WANTED=$(( RAM_AVAIL / 2 ))
    RAM_WANTED=$(( RAM_WANTED / 1048577 ))
    RAM_SIZE="${RAM_WANTED}M"
  else
    RAM_SIZE="${RAM_WANTED}G"
  fi

fi

if [[ "${RAM_SIZE,,}" == "max" ]]; then

  RAM_WANTED=$(( RAM_AVAIL - (RAM_SPARE * 3) ))
  RAM_WANTED=$(( RAM_WANTED / 1073741825 ))

  if (( "$RAM_WANTED" < 1 )); then

    RAM_WANTED=$(( RAM_AVAIL - (RAM_SPARE * 2) ))
    RAM_WANTED=$(( RAM_WANTED / 1073741825 ))

    if (( "$RAM_WANTED" < 1 )); then

      RAM_WANTED=$(( RAM_AVAIL - RAM_SPARE ))
      RAM_WANTED=$(( RAM_WANTED / 1073741825 ))

      if (( "$RAM_WANTED" < 1 )); then

        RAM_WANTED=$(( RAM_AVAIL - RAM_SPARE ))
        RAM_WANTED=$(( RAM_WANTED / 1048577 ))

        if (( "$RAM_WANTED" < 1 )); then

          RAM_WANTED=$(( RAM_AVAIL ))
          RAM_WANTED=$(( RAM_WANTED / 1048577 ))

        fi

        RAM_SIZE="${RAM_WANTED}M"
      else
        RAM_SIZE="${RAM_WANTED}G"
      fi
    else
      RAM_SIZE="${RAM_WANTED}G"
    fi
  else
    RAM_SIZE="${RAM_WANTED}G"
  fi

fi

return 0
