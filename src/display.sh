#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables

: ${GPU:='N'}           # GPU passthrough
: ${DISPLAY:='none'}  # Display type

case "${DISPLAY,,}" in
  vnc)
    DISPLAY_OPTS="-display vnc=:0 -vga virtio"
    ;;
  *)
    DISPLAY_OPTS="-display $DISPLAY -vga none"
    ;;
esac

if [[ "$GPU" != [Yy1]* ]] || [[ "$ARCH" != "amd64" ]]; then
  return 0
fi

DISPLAY_OPTS="-display egl-headless,rendernode=/dev/dri/renderD128 -vga virtio"
[[ "${DISPLAY,,}" == "vnc" ]] && DISPLAY_OPTS="$DISPLAY_OPTS -vnc :0"

[ ! -d /dev/dri ] && mkdir -m 755 /dev/dri

if [ ! -c /dev/dri/card0 ]; then
  if mknod /dev/dri/card0 c 226 0; then
    chmod 666 /dev/dri/card0
  fi
fi

if [ ! -c /dev/dri/renderD128 ]; then
  if mknod /dev/dri/renderD128 c 226 128; then
    chmod 666 /dev/dri/renderD128
  fi
fi

addPackage "xserver-xorg-video-intel" "Intel GPU drivers"
addPackage "qemu-system-modules-opengl" "OpenGL module"

return 0
