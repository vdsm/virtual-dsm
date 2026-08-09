#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables

: "${GPU:="N"}"         # GPU passthrough
: "${VGA:="virtio"}"    # VGA adaptor
: "${DISPLAY:="none"}"  # Display type
: "${LOSSY:="N"}"       # Lossy VNC compression
: "${RENDERNODE:="/dev/dri/renderD128"}"  # Render node

# Sanitize variables
VGA=$(strip "$VGA")
LOSSY=$(strip "$LOSSY")
DISPLAY=$(strip "$DISPLAY")
RENDERNODE=$(strip "$RENDERNODE")

CPU_VENDOR=$(lscpu | awk '/Vendor ID/{print $3}')

# The accelerated Intel render-node path is restricted to x86 Intel hosts;
# other platforms retain the normal QEMU display backend.
if ! enabled "$GPU" || isAmdCpu || [[ "$ARCH" != "amd64" ]]; then

  # A disabled frontend also removes the emulated VGA device to keep the guest
  # hardware layout headless.
  [[ "${DISPLAY,,}" == "none" ]] && VGA="none"

  if enabled "$LOSSY" && [[ "${DISPLAY,,}" == vnc=* ]]; then
    DISPLAY+=",lossy=on"
  fi

  DISPLAY_OPTS="-display ${DISPLAY} -vga ${VGA}"
  return 0

fi

msg="Configuring display drivers..."
html "$msg"
enabled "$DEBUG" && echo "$msg"

DISPLAY_OPTS="-display egl-headless,rendernode=${RENDERNODE}"
DISPLAY_OPTS+=" -vga $VGA"

[ ! -d /dev/dri ] && mkdir -m 755 /dev/dri

# Extract the card number from the render node
# Linux renderD128 corresponds to card0; derive both device minors because
# container device bindings may expose only the render node.
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

if [ ! -c "$RENDERNODE" ] || [ ! -r "$RENDERNODE" ] || [ ! -w "$RENDERNODE" ]; then
  warn "render device '${RENDERNODE}' is unavailable or inaccessible."
fi

# Install acceleration packages lazily so non-GPU deployments keep the base
# image small and do not require OpenGL modules.
addDsmPackage "xserver-xorg-video-intel" "Intel GPU drivers"
addDsmPackage "qemu-system-modules-opengl" "OpenGL module"

return 0
