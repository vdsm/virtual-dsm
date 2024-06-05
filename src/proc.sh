#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables

: "${KVM:="Y"}"
: "${HOST_CPU:=""}"
: "${CPU_FLAGS:=""}"
: "${CPU_MODEL:=""}"
: "${DEF_MODEL:="qemu64"}"

if [[ "${ARCH,,}" != "amd64" ]]; then
  KVM="N"
  warn "your CPU architecture is ${ARCH^^} and cannot provide KVM acceleration for x64 instructions, this will cause a major loss of performance."
fi

if [[ "$KVM" != [Nn]* ]]; then

  KVM_ERR=""

  if [ ! -e /dev/kvm ]; then
    KVM_ERR="(device file missing)"
  else
    if ! sh -c 'echo -n > /dev/kvm' &> /dev/null; then
      KVM_ERR="(no write access)"
    else
      flags=$(sed -ne '/^flags/s/^.*: //p' /proc/cpuinfo)
      if ! grep -qw "vmx\|svm" <<< "$flags"; then
        KVM_ERR="(vmx/svm disabled)"
      fi
    fi
  fi

  if [ -n "$KVM_ERR" ]; then
    KVM="N"
    if [[ "$OSTYPE" =~ ^darwin ]]; then
      warn "you are using MacOS which has no KVM support, this will cause a major loss of performance."
    else
      if grep -qi Microsoft /proc/version; then
        warn "you are using Windows 10 which has no KVM support, this will cause a major loss of performance."
      else
        error "KVM acceleration not available $KVM_ERR, this will cause a major loss of performance."
        error "See the FAQ on how to enable it, or continue without KVM by setting KVM=N (not recommended)."
        [[ "$DEBUG" != [Yy1]* ]] && exit 88
      fi
    fi
  fi

fi

if [[ "$KVM" != [Nn]* ]]; then

  CPU_FEATURES="kvm=on,l3-cache=on,+hypervisor"
  KVM_OPTS=",accel=kvm -enable-kvm -global kvm-pit.lost_tick_policy=discard"

  if ! grep -qw "sse4_2" <<< "$flags"; then
    info "Your CPU does not have the SSE4 instruction set that Virtual DSM requires, it will be emulated..."
    [ -z "$CPU_MODEL" ] && CPU_MODEL="$DEF_MODEL"
    CPU_FEATURES="$CPU_FEATURES,+ssse3,+sse4.1,+sse4.2"
  fi

  if [ -z "$CPU_MODEL" ]; then
    CPU_MODEL="host"
    CPU_FEATURES="$CPU_FEATURES,migratable=no"
  fi

else

  KVM_OPTS=""
  CPU_FEATURES="l3-cache=on,+hypervisor"

  if [[ "$ARCH" == "amd64" ]]; then
    KVM_OPTS=" -accel tcg,thread=multi"
  fi

  if [ -z "$CPU_MODEL" ]; then
    if [[ "$ARCH" == "amd64" ]]; then
      CPU_MODEL="max"
      CPU_FEATURES="$CPU_FEATURES,migratable=no"
    else
      CPU_MODEL="$DEF_MODEL"
    fi
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
  HOST_CPU=$(lscpu | grep -m 1 'Model name' | cut -f 2 -d ":" | awk '{$1=$1}1' | sed 's# @.*##g' | sed s/"(R)"//g | sed 's/[^[:alnum:] ]\+/ /g' | sed 's/  */ /g')
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
