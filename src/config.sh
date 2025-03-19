#!/usr/bin/env bash
set -Eeuo pipefail

DEF_OPTS="-nodefaults -boot strict=on"
RAM_OPTS=$(echo "-m ${RAM_SIZE^^}" | sed 's/MB/M/g;s/GB/G/g;s/TB/T/g')
CPU_OPTS="-cpu $CPU_FLAGS -smp $CPU_CORES,sockets=1,dies=1,cores=$CPU_CORES,threads=1"
MAC_OPTS="-machine type=q35,smm=off,usb=off,vmport=off,dump-guest-core=off,hpet=off${KVM_OPTS}"
DEV_OPTS="-device virtio-balloon-pci,id=balloon0,bus=pcie.0,addr=0x4"
DEV_OPTS+=" -object rng-random,id=objrng0,filename=/dev/urandom"
DEV_OPTS+=" -device virtio-rng-pci,rng=objrng0,id=rng0,bus=pcie.0,addr=0x1c"

ARGS="$DEF_OPTS $CPU_OPTS $RAM_OPTS $MAC_OPTS $DISPLAY_OPTS $MON_OPTS $SERIAL_OPTS $NET_OPTS $DISK_OPTS $DEV_OPTS $ARGUMENTS"
ARGS=$(echo "$ARGS" | sed 's/\t/ /g' | tr -s ' ')

# Check available memory as the very last step

if [[ "$RAM_CHECK" != [Nn]* ]]; then

  RAM_AVAIL=$(free -b | grep -m 1 Mem: | awk '{print $7}')
  AVAIL_MEM=$(formatBytes "$RAM_AVAIL")

  if (( (RAM_WANTED + RAM_SPARE) > RAM_AVAIL )); then
    msg="Your configured RAM_SIZE of ${RAM_SIZE/G/ GB} is too high for the $AVAIL_MEM of memory available, please set a lower value."
    [[ "${FS,,}" != "zfs" ]] && error "$msg" && exit 17
    info "$msg"
  else
    if (( (RAM_WANTED + (RAM_SPARE * 3)) > RAM_AVAIL )); then
      msg="your configured RAM_SIZE of ${RAM_SIZE/G/ GB} is very close to the $AVAIL_MEM of memory available, please consider a lower value."
      if [[ "${FS,,}" != "zfs" ]]; then
        warn "$msg"
      else
        info "$msg"
      fi
    fi
  fi

fi

if [[ "$DEBUG" == [Yy1]* ]]; then
  printf "Arguments:\n\n%s\n\n" "${ARGS// -/$'\n-'}"
fi

return 0
