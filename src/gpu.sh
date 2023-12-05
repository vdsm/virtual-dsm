#!/bin/bash
set -Eeuo pipefail

if [[ "${GPU}" != [Yy1]* ]] || [[ "$ARCH" != "amd64" ]]; then
  return 0
fi

[ ! -d /dev/dri ] && mkdir -m 755 /dev/dri

if [ ! -c /dev/dri/card0 ]; then
  mknod /dev/dri/card0 c 226 0
fi

if [ ! -c /dev/dri/renderD128 ]; then
  mknod /dev/dri/renderD128 c 226 128
fi

chmod 666 /dev/dri/card0
chmod 666 /dev/dri/renderD128

addPackage "xserver-xorg-video-intel" "Intel GPU drivers"
addPackage "qemu-system-modules-opengl" "OpenGL module"

return 0
