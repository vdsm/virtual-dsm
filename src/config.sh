#!/usr/bin/env bash
set -Eeuo pipefail

DEF_OPTS="-nodefaults -boot strict=on -display none -vga none"
RAM_OPTS=$(echo "-m $RAM_SIZE" | sed 's/MB/M/g;s/GB/G/g;s/TB/T/g')
CPU_OPTS="-cpu $CPU_MODEL -smp $CPU_CORES,sockets=1,dies=1,cores=$CPU_CORES,threads=1"
MAC_OPTS="-machine type=q35,usb=off,dump-guest-core=off,hpet=off${KVM_OPTS}"

EXTRA_OPTS="-device virtio-balloon-pci,id=balloon0,bus=pcie.0,addr=0x4"
EXTRA_OPTS="$EXTRA_OPTS -object rng-random,id=objrng0,filename=/dev/urandom"
EXTRA_OPTS="$EXTRA_OPTS -device virtio-rng-pci,rng=objrng0,id=rng0,bus=pcie.0,addr=0x1c"
[[ "$CONSOLE" != [Yy]* ]] && EXTRA_OPTS="$EXTRA_OPTS -daemonize -D $QEMU_LOG"

if [[ "$GPU" == [Yy1]* ]] && [[ "$ARCH" == "amd64" ]]; then
  DEF_OPTS="-nodefaults -boot strict=on -display egl-headless,rendernode=/dev/dri/renderD128"
  EXTRA_OPTS="$EXTRA_OPTS -device virtio-vga,id=video0,max_outputs=1,bus=pcie.0,addr=0x1"
fi

ARGS="$DEF_OPTS $CPU_OPTS $RAM_OPTS $MAC_OPTS $MON_OPTS $SERIAL_OPTS $NET_OPTS $DISK_OPTS $EXTRA_OPTS $ARGUMENTS"
ARGS=$(echo "$ARGS" | sed 's/\t/ /g' | tr -s ' ')

return 0
