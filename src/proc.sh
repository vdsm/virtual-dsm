#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables

: "${KVM:="Y"}"
: "${HOST_CPU:=""}"
: "${CPU_FLAGS:=""}"
: "${CPU_MODEL:="qemu64"}"

[ "$ARCH" != "amd64" ] && KVM="N"

if [[ "$KVM" != [Nn]* ]]; then

  KVM_ERR=""

  if [ ! -e /dev/kvm ]; then
    KVM_ERR="(device file missing)"
  else
    if ! sh -c 'echo -n > /dev/kvm' &> /dev/null; then
      KVM_ERR="(no write access)"
    else
      if ! grep -q -e vmx -e svm /proc/cpuinfo; then
        KVM_ERR="(vmx/svm disabled)"
      fi
    fi
  fi

  if [ -n "$KVM_ERR" ]; then
    KVM="N"
    error "KVM acceleration not detected $KVM_ERR, this will cause a major loss of performance."
    error "See the FAQ on how to enable it, or continue without KVM by setting KVM=N (not recommended)."
    [[ "$DEBUG" != [Yy1]* ]] && exit 88
  fi

fi

if [[ "$KVM" != [Nn]* ]]; then

  CPU_MODEL="host"
  KVM_OPTS=",accel=kvm -enable-kvm"
  CPU_FEATURES="kvm=on,l3-cache=on,migratable=no"

  if ! grep -qE '^flags.* (sse4_2)' /proc/cpuinfo; then
    error "Your host CPU does not have the SSE4.2 instruction set that Virtual DSM requires to boot."
    error "Disable KVM by setting KVM=N to emulate a compatible CPU, at the cost of performance."
    [[ "$DEBUG" != [Yy1]* ]] && exit 89
  fi

else

  KVM_OPTS=""
  CPU_FEATURES="l3-cache=on"

  if [[ "$ARCH" == "amd64" ]]; then
      CPU_MODEL="max"
      CPU_FEATURES="$CPU_FEATURES,migratable=no"
  fi

  CPU_FEATURES="$CPU_FEATURES,+ssse3,+sse4.1,+sse4.2"

fi

if [ -z "$CPU_FLAGS" ]; then
  if [ -z "$CPU_FEATURES" ]; then
    CPU_FLAGS="$CPU_MODEL"
  else
    CPU_FLAGS="$CPU_MODEL,$CPU_FEATURES"
  fi
else
  if [ -z "$CPU_FEATURES" ]; then
    CPU_FLAGS="$CPU_MODEL,$CPU_FLAGS"
  else
    CPU_FLAGS="$CPU_MODEL,$CPU_FEATURES,$CPU_FLAGS"
  fi
fi

if [ -z "$HOST_CPU" ]; then
  HOST_CPU=$(lscpu | grep 'Model name' | cut -f 2 -d ":" | awk '{$1=$1}1' | sed 's# @.*##g' | sed s/"(R)"//g | sed 's/[^[:alnum:] ]\+/ /g' | sed 's/  */ /g')
fi

if [ -n "$HOST_CPU" ]; then
  HOST_CPU="${HOST_CPU%%,*},,"
else
  HOST_CPU="QEMU, Virtual CPU,"
  if [ "$ARCH" == "amd64" ]; then
    HOST_CPU="$HOST_CPU X86_64"
  else
    HOST_CPU="$HOST_CPU $ARCH"
  fi
fi

return 0
