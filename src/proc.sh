#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables

: "${HOST_CPU:=""}"
: "${CPU_FLAGS:=""}"
: "${CPU_MODEL:=""}"

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

flags=$(sed -ne '/^flags/s/^.*: //p' /proc/cpuinfo)

if [[ "$KVM" != [Nn]* ]]; then

  CPU_FEATURES="kvm=on,l3-cache=on,+hypervisor"
  KVM_OPTS=",accel=kvm -enable-kvm -global kvm-pit.lost_tick_policy=discard"

  if ! grep -qw "sse4_2" <<< "$flags"; then
    info "Your CPU does not have the SSE4 instruction set that Virtual DSM requires, it will be emulated..."
    [ -z "$CPU_MODEL" ] && CPU_MODEL="qemu64"
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
      CPU_MODEL="qemu64"
    fi
  fi

  CPU_FEATURES+=",+ssse3,+sse4.1,+sse4.2"

fi

if [[ "$ARGUMENTS" == *"-cpu host,"* ]]; then

  args="${ARGUMENTS} "
  prefix="${args/-cpu host,*/}"
  suffix="${args/*-cpu host,/}"
  param="${suffix%% *}"
  suffix="${suffix#* }"
  args="${prefix}${suffix}"
  ARGUMENTS="${args::-1}"

  if [ -z "$CPU_FLAGS" ]; then
    CPU_FLAGS="$param"
  else
    CPU_FLAGS+=",$param"
  fi

else

  if [[ "$ARGUMENTS" == *"-cpu host"* ]]; then
    ARGUMENTS="${ARGUMENTS//-cpu host/}"
  fi

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
