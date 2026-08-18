#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables

: "${GPU:="N"}"         # GPU acceleration
: "${VGA:="virtio"}"    # VGA adaptor
: "${DISPLAY:="none"}"  # Display type
: "${LOSSY:="N"}"       # Lossy VNC compression
: "${RENDERNODE:="/dev/dri/renderD128"}"  # Render node

# Sanitize variables
VGA=$(strip "$VGA")
LOSSY=$(strip "$LOSSY")
DISPLAY=$(strip "$DISPLAY")
VNC_PORT=$(strip "$VNC_PORT")
RENDERNODE=$(strip "$RENDERNODE")

port=$(( VNC_PORT - 5900 ))

LOSSY_OPT=""
enabled "$LOSSY" && LOSSY_OPT=",lossy=on"

case "${DISPLAY,,}" in

  "vnc" )
    DISPLAY_OPTS="-display vnc=:${port}${LOSSY_OPT} -vga ${VGA}" ;;
  "disabled" )
    DISPLAY_OPTS="-display none -vga ${VGA}" ;;
  "none" )
    DISPLAY_OPTS="-display none -vga none" ;;
  *)
    DISPLAY_OPTS="-display ${DISPLAY} -vga ${VGA}" ;;

esac

enabled "$GPU" || return 0

msg="Configuring display drivers..."
enabled "$DEBUG" && echo "$msg"

if [[ "$ARCH" != "amd64" ]]; then
  warn "GPU acceleration is only supported for the AMD64 platform, ignoring GPU=Y."
  return 0
fi

RENDER_NAME="${RENDERNODE##*/}"

if [[ ! "$RENDER_NAME" =~ ^renderD([0-9]+)$ ]]; then
  warn "invalid render node '$RENDERNODE', ignoring GPU=Y."
  return 0
fi

CARD_NUMBER="${BASH_REMATCH[1]}"
VENDOR_FILE="/sys/class/drm/${RENDER_NAME}/device/vendor"

if [ ! -r "$VENDOR_FILE" ]; then
  warn "cannot determine the GPU vendor for '$RENDERNODE', ignoring GPU=Y."
  return 0
fi

GPU_VENDOR=$(< "$VENDOR_FILE")
case "${GPU_VENDOR,,}" in
  "0x8086" | "0x1002" ) ;;
  * )
    warn "GPU acceleration is only supported for Intel and AMD GPUs, ignoring GPU=Y."
    return 0 ;;
esac

[ ! -d /dev/dri ] && mkdir -m 755 /dev/dri

# Derive the matching DRM card from the validated render node number.
CARD_DEVICE="/dev/dri/card$((CARD_NUMBER - 128))"

# Containers normally have no udev, so reconstruct the matching DRM card and
# render character devices from the render-node minor number when necessary.
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
  warn "render device '$RENDERNODE' is unavailable or inaccessible, ignoring GPU=Y."
  return 0
fi

[[ "${VGA,,}" == "virtio" ]] && VGA="virtio-vga-gl"

DISPLAY_OPTS="-display egl-headless,rendernode=$RENDERNODE"
DISPLAY_OPTS+=" -device $VGA"

[[ "${DISPLAY,,}" == "vnc" ]] && DISPLAY_OPTS+=" -vnc :${port}${LOSSY_OPT}"

return 0
