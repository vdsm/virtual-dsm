#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables

: "${KVM:="Y"}"
: "${HOST_CPU:=""}"
: "${CPU_FLAGS:=""}"
: "${CPU_MODEL:=""}"
: "${DEF_MODEL:="qemu64"}"

CLOCKSOURCE="tsc"
[[ "${ARCH,,}" == "arm64" ]] && CLOCKSOURCE="arch_sys_counter"
CLOCK="/sys/devices/system/clocksource/clocksource0/current_clocksource"

if [ ! -f "$CLOCK" ]; then
  warn "file \"$CLOCK\" cannot not found?"
else
  result=$(<"$CLOCK")
  result="${result//[![:print:]]/}"
  case "${result,,}" in
    "${CLOCKSOURCE,,}" ) ;;
    "kvm-clock" ) info "Nested KVM virtualization detected.." ;;
    "hyperv_clocksource_tsc_page" ) info "Nested Hyper-V virtualization detected.." ;;
    "hpet" ) warn "unsupported clock source ﻿detected﻿: '$result'. Please﻿ ﻿set host clock source to '$CLOCKSOURCE'." ;;
    *) warn "unexpected clock source ﻿detected﻿: '$result'. Please﻿ ﻿set host clock source to '$CLOCKSOURCE'." ;;
  esac
fi

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
      warn "you are using macOS which has no KVM support, this will cause a major loss of performance."
    else
      error "KVM acceleration not available $KVM_ERR, this will cause a major loss of performance."
      error "See the FAQ on how to diagnose the cause, or continue without KVM by setting KVM=N (not recommended)."
      [[ "$DEBUG" != [Yy1]* ]] && exit 88
    fi
  fi

fi

if [[ "$KVM" != [Nn]* ]]; then

  CPU_FEATURES="kvm=on,l3-cache=on,+hypervisor"
  KVM_OPTS=",accel=kvm -enable-kvm -global kvm-pit.lost_tick_policy=discard"

  if ! grep -qw "sse4_2" <<< "$flags"; then
    info "Your CPU does not have the SSE4 instruction set that Virtual DSM requires, it will be emulated..."
    [ -z "$CPU_MODEL" ] && CPU_MODEL="$DEF_MODEL"
    CPU_FEATURES+=",+ssse3,+sse4.1,+sse4.2"
  fi

  if [ -z "$CPU_MODEL" ]; then
    CPU_MODEL="host"
    CPU_FEATURES+=",migratable=no"
  fi

  if grep -qw "svm" <<< "$flags"; then

    # AMD processor

    if grep -qw "tsc_scale" <<< "$flags"; then
      CPU_FEATURES+=",+invtsc"
    fi

  else

    # Intel processor

    vmx=$(sed -ne '/^vmx flags/s/^.*: //p' /proc/cpuinfo)

    if grep -qw "tsc_scaling" <<< "$vmx"; then
      CPU_FEATURES+=",+invtsc"
    fi

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
      CPU_FEATURES+=",migratable=no"
    else
      CPU_MODEL="$DEF_MODEL"
    fi
  fi

  CPU_FEATURES+=",+ssse3,+sse4.1,+sse4.2"

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
  [[ "${CPU,,}" != "unknown" ]] && HOST_CPU="$CPU"
fi

if [ -n "$HOST_CPU" ]; then
  HOST_CPU="${HOST_CPU%%,*},,"
else
  HOST_CPU="QEMU, Virtual CPU,"
  if [ "$ARCH" == "amd64" ]; then
    HOST_CPU+=" X86_64"
  else
    HOST_CPU+=" $ARCH"
  fi
fi

return 0
