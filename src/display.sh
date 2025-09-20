#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables

: "${GPU:="N"}"         # GPU passthrough
: "${VGA:="virtio"}"    # VGA adaptor
: "${DISPLAY:="none"}"  # Display type
: "${RENDERNODE:="/dev/dri/renderD128"}"  # Render node

CPU_VENDOR=$(lscpu | awk '/Vendor ID/{print $3}')

if [[ "$GPU" != [Yy1]* || "$CPU_VENDOR" != "GenuineIntel" || "$ARCH" != "amd64" ]]; then

  [[ "${DISPLAY,,}" == "none" ]] && VGA="none"
  DISPLAY_OPTS="-display $DISPLAY -vga $VGA"
  return 0

fi

DISPLAY_OPTS="-display egl-headless,rendernode=$RENDERNODE"
DISPLAY_OPTS+=" -vga $VGA"

[ ! -d /dev/dri ] && mkdir -m 755 /dev/dri

# Extract the card number from the render node
CARD_NUMBER=$(echo "$RENDERNODE" | grep -oP '(?<=renderD)\d+')
CARD_DEVICE="/dev/dri/card$((CARD_NUMBER - 128))"

if [ ! -c "$CARD_DEVICE" ]; then
  if mknod "$CARD_DEVICE" c 226 $((CARD_NUMBER - 128)); then
    chmod 666 "$CARD_DEVICE"
  fi
fi

if [ ! -c "$RENDERNODE" ]; then
  if mknod "$RENDERNODE" c 226 "$CARD_NUMBER"; then
    chmod 666 "$RENDERNODE"
  fi
fi

addPackage "xserver-xorg-video-intel" "Intel GPU drivers"
addPackage "qemu-system-modules-opengl" "OpenGL module"

return 0
