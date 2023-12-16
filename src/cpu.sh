#!/bin/bash
set -Eeuo pipefail

KVM_ERR=""
KVM_OPTS=""
QEMU_CPU="qemu64,+ssse3,+sse4,+sse4.1,+sse4.2"

if [ "$ARCH" == "amd64" ]; then

  if [ -e /dev/kvm ] && sh -c 'echo -n > /dev/kvm' &> /dev/null; then
    if ! grep -q -e vmx -e svm /proc/cpuinfo; then
      KVM_ERR="(vmx/svm disabled)"
    fi
  else
    [ -e /dev/kvm ] && KVM_ERR="(no write access)" || KVM_ERR="(device file missing)"
  fi

  if [ -n "$KVM_ERR" ]; then
    error "KVM acceleration not detected $KVM_ERR, this will cause a major loss of performance."
    error "See the FAQ on how to enable it, or skip this error by setting KVM=N (not recommended)."
    [[ "$KVM" != [Nn]* ]] && [[ "$DEBUG" != [Yy1]* ]] && exit 88
    [ "$CPU_MODEL" == "host"* ] && CPU_MODEL="$QEMU_CPU"
  else
    KVM_OPTS=",accel=kvm -enable-kvm"
  fi

  if [ "$CPU_MODEL" == "host" ]; then
    if ! grep -qE '^flags.* (sse4_2)' /proc/cpuinfo; then
      info "Your CPU does not have the SSE4.2 instruction set, it will be emulated.."
      CPU_MODEL="host,+ssse3,+sse4,+sse4.1,+sse4.2"
    fi
  fi
else
  [ "$CPU_MODEL" == "host"* ] && CPU_MODEL="$QEMU_CPU"
fi

return 0
