#!/bin/bash
set -eu

# Docker environment variables

: ${HOST_CPU:=''}
: ${HOST_BUILD:='42962'}
: ${HOST_VERSION:='2.6.1-12139'}
: ${HOST_TIMESTAMP:='1679863686'}
: ${HOST_SERIAL:='0000000000000'}
: ${GUEST_SERIAL:='0000000000000'}

if [ -z "$HOST_CPU" ]; then
  HOST_CPU=$(lscpu | sed -nr '/Model name/ s/.*:\s*(.*) @ .*/\1/p' | sed ':a;s/  / /;ta' | sed s/"(R)"//g | sed 's/[^[:alnum:] ]\+/ /g' | sed 's/  */ /g')
fi

if [ -n "$HOST_CPU" ]; then
  HOST_CPU="$HOST_CPU,,"
else
  HOST_CPU="QEMU, Virtual CPU, X86_64"
fi

ARGS="-cpu_arch=${HOST_CPU}"

[ -z "$CPU_CORES" ] && ARGS="$ARGS -cpu=${CPU_CORES}"
[ -z "$HOST_BUILD" ] && ARGS="$ARGS -build=${HOST_BUILD}"
[ -z "$HOST_SERIAL" ] && ARGS="$ARGS -hostsn=${HOST_SERIAL}" 
[ -z "$GUEST_SERIAL" ] && ARGS="$ARGS -guestsn=${GUEST_SERIAL}"  
[ -z "$HOST_VERSION" ] && ARGS="$ARGS -version=${HOST_VERSION}"
[ -z "$HOST_TIMESTAMP" ] && ARGS="$ARGS -ts=${HOST_TIMESTAMP}"

./run/host.bin ${ARGS:+ $ARGS} > /dev/null 2>&1 &

SERIAL_OPTS="\
	-serial mon:stdio \
	-device virtio-serial-pci,id=virtio-serial0,bus=pcie.0,addr=0x3 \
	-chardev pty,id=charserial0 \
	-device isa-serial,chardev=charserial0,id=serial0 \
	-chardev socket,id=charchannel0,host=127.0.0.1,port=12345,reconnect=10 \
	-device virtserialport,bus=virtio-serial0.0,nr=1,chardev=charchannel0,id=channel0,name=vchannel"
