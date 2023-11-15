#!/bin/bash
set -Eeuo pipefail

# Docker environment variables

: ${HOST_CPU:=''}
: ${HOST_MAC:=''}
: ${HOST_DEBUG:=''}
: ${HOST_SERIAL:=''}
: ${HOST_MODEL:=''}
: ${GUEST_SERIAL:=''}

if [ -z "$HOST_CPU" ]; then
  HOST_CPU=$(lscpu | grep 'Model name' | cut -f 2 -d ":" | awk '{$1=$1}1' | sed 's# @.*##g' | sed s/"(R)"//g | sed 's/[^[:alnum:] ]\+/ /g' | sed 's/  */ /g')
fi

if [ -n "$HOST_CPU" ]; then
  HOST_CPU="$HOST_CPU,,"
else
  if [ "$ARCH" == "amd64" ]; then
    HOST_CPU="QEMU, Virtual CPU, X86_64"
  else
    HOST_CPU="QEMU, Virtual CPU, $ARCH"
  fi
fi

HOST_ARGS=()
HOST_ARGS+=("-cpu=${CPU_CORES}")
HOST_ARGS+=("-cpu_arch=${HOST_CPU}")

[ -n "$HOST_MAC" ] && HOST_ARGS+=("-mac=${HOST_MAC}")
[ -n "$HOST_MODEL" ] && HOST_ARGS+=("-model=${HOST_MODEL}")
[ -n "$HOST_SERIAL" ] && HOST_ARGS+=("-hostsn=${HOST_SERIAL}")
[ -n "$GUEST_SERIAL" ] && HOST_ARGS+=("-guestsn=${GUEST_SERIAL}")

if [[ "${HOST_DEBUG}" == [Yy1]* ]]; then
  set -x
  ./host.bin "${HOST_ARGS[@]}" &
  { set +x; } 2>/dev/null
  echo
else
  ./host.bin "${HOST_ARGS[@]}" >/dev/null &
fi

cnt=0
sleep 0.2

while ! nc -z -w1 127.0.0.1 2210 > /dev/null 2>&1; do
  sleep 0.1
  cnt=$((cnt + 1))
  (( cnt > 20 )) && error "Failed to connect to qemu-host.." && exit 58
done

cnt=0

while ! nc -z -w1 127.0.0.1 12345 > /dev/null 2>&1; do
  sleep 0.1
  cnt=$((cnt + 1))
  (( cnt > 20 )) && error "Failed to connect to qemu-host.." && exit 59
done

# Configure serial ports

SERIAL_OPTS="\
        -serial mon:stdio \
        -device virtio-serial-pci,id=virtio-serial0,bus=pcie.0,addr=0x3 \
        -chardev pty,id=charserial0 \
        -device isa-serial,chardev=charserial0,id=serial0 \
        -chardev socket,id=charchannel0,host=127.0.0.1,port=12345,reconnect=10 \
        -device virtserialport,bus=virtio-serial0.0,nr=1,chardev=charchannel0,id=channel0,name=vchannel"

return 0
