#!/bin/bash
set -Eeuo pipefail

[ ! -d /dev/dri ] && mkdir -m 755 /dev/dri

if [ ! -c /dev/dri/card0 ]; then
  mknod /dev/dri/card0 c 226 0
fi

if [ ! -c /dev/dri/renderD128 ]; then
  mknod /dev/dri/renderD128 c 226 128
fi

chmod 666 /dev/dri/card0
chmod 666 /dev/dri/renderD128

DEF_OPTS="-nodefaults -boot strict=on -display egl-headless,rendernode=/dev/dri/renderD128"
DEF_OPTS="${DEF_OPTS} -device virtio-vga,id=video0,max_outputs=1,bus=pcie.0,addr=0x1"

if ! apt-mark showinstall | grep -q "xserver-xorg-video-intel"; then

  info "Installing Intel GPU drivers..."

  export DEBCONF_NOWARNINGS="yes"
  export DEBIAN_FRONTEND="noninteractive"

  apt-get -qq update
  apt-get -qq --no-install-recommends -y install xserver-xorg-video-intel > /dev/null

fi

if ! apt-mark showinstall | grep -q "qemu-system-modules-opengl"; then

  info "Installing OpenGL module..."

  export DEBCONF_NOWARNINGS="yes"
  export DEBIAN_FRONTEND="noninteractive"

  apt-get -qq update
  apt-get -qq --no-install-recommends -y install qemu-system-modules-opengl > /dev/null

fi
