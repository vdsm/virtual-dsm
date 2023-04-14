#!/bin/bash
set -eu

# Docker environment variabeles

: ${HOST_CPU:=''}
: ${HOST_BUILD:='42962'}
: ${HOST_VERSION:='2.6.1-12139'}
: ${HOST_TIMESTAMP:='1679863686'}
: ${HOST_SERIAL:='0000000000000'}
: ${GUEST_SERIAL:='0000000000000'}
: ${GUEST_UUID:='ba13a19a-c0c1-4fef-9346-915ed3b98341'}

if [ -z "$HOST_CPU" ]; then
  HOST_CPU=$(lscpu | sed -nr '/Model name/ s/.*:\s*(.*) @ .*/\1/p' | sed ':a;s/  / /;ta' | sed s/"(R)"//g | sed s/"-"//g | sed 's/[^[:alnum:] ]\+//g')
fi

if [ -n "$HOST_CPU" ]; then
  HOST_CPU="$HOST_CPU,,"
else
  HOST_CPU="QEMU, Virtual CPU, X86_64"
fi

./run/serial.bin -cpu="${CPU_CORES}" \
		 -cpu_arch="${HOST_CPU}" \
		 -hostsn="${HOST_SERIAL}" \
		 -guestsn="${GUEST_SERIAL}" \
		 -vmmts="${HOST_TIMESTAMP}" \
		 -vmmversion="${HOST_VERSION}" \
		 -buildnumber="${HOST_BUILD}" \
		 -guestuuid="${GUEST_UUID}" > /dev/null 2>&1 &

KVM_SERIAL_OPTS="\
	-serial mon:stdio \
	-device virtio-serial-pci,id=virtio-serial0,bus=pcie.0,addr=0x3 \
	-chardev pty,id=charserial0 \
	-device isa-serial,chardev=charserial0,id=serial0 \
	-chardev socket,id=charchannel0,host=127.0.0.1,port=12345,reconnect=10 \
	-device virtserialport,bus=virtio-serial0.0,nr=1,chardev=charchannel0,id=channel0,name=vchannel"
