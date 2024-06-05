#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables

: "${HOST_MAC:=""}"
: "${HOST_DEBUG:=""}"
: "${HOST_SERIAL:=""}"
: "${HOST_MODEL:=""}"
: "${GUEST_SERIAL:=""}"

if [ -n "$HOST_MAC" ]; then

  HOST_MAC="${HOST_MAC//-/:}"

  if [[ ${#HOST_MAC} == 12 ]]; then
    m="$HOST_MAC"
    HOST_MAC="${m:0:2}:${m:2:2}:${m:4:2}:${m:6:2}:${m:8:2}:${m:10:2}"
  fi

  if [[ ${#HOST_MAC} != 17 ]]; then
    error "Invalid HOST_MAC address: '$HOST_MAC', should be 12 or 17 digits long!" && exit 28
  fi

fi

HOST_ARGS=()
HOST_ARGS+=("-cpu=$CPU_CORES")
HOST_ARGS+=("-cpu_arch=$HOST_CPU")

[ -n "$HOST_MAC" ] && HOST_ARGS+=("-mac=$HOST_MAC")
[ -n "$HOST_MODEL" ] && HOST_ARGS+=("-model=$HOST_MODEL")
[ -n "$HOST_SERIAL" ] && HOST_ARGS+=("-hostsn=$HOST_SERIAL")
[ -n "$GUEST_SERIAL" ] && HOST_ARGS+=("-guestsn=$GUEST_SERIAL")

if [[ "$HOST_DEBUG" == [Yy1]* ]]; then
  set -x
  ./host.bin "${HOST_ARGS[@]}" &
  { set +x; } 2>/dev/null
  echo
else
  ./host.bin "${HOST_ARGS[@]}" >/dev/null &
fi

cnt=0
sleep 0.2

while ! nc -z -w2 127.0.0.1 2210 > /dev/null 2>&1; do
  sleep 0.1
  cnt=$((cnt + 1))
  (( cnt > 50 )) && error "Failed to connect to qemu-host.." && exit 58
done

cnt=0

while ! nc -z -w2 127.0.0.1 12345 > /dev/null 2>&1; do
  sleep 0.1
  cnt=$((cnt + 1))
  (( cnt > 50 )) && error "Failed to connect to qemu-host.." && exit 59
done

# Configure serial ports

if [[ "$CONSOLE" != [Yy]* ]]; then
  SERIAL_OPTS="-serial pty"
else
  SERIAL_OPTS="-serial mon:stdio"
fi

SERIAL_OPTS+=" \
        -device virtio-serial-pci,id=virtio-serial0,bus=pcie.0,addr=0x3 \
        -chardev socket,id=charchannel0,host=127.0.0.1,port=12345,reconnect=10 \
        -device virtserialport,bus=virtio-serial0.0,nr=1,chardev=charchannel0,id=channel0,name=vchannel"

return 0
