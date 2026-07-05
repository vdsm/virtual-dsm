#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables

: "${HOST_CPU:=""}"
: "${CPU_FLAGS:=""}"
: "${CPU_MODEL:=""}"

HOST_CPU=$(strip "$HOST_CPU")
CPU_FLAGS=$(strip "$CPU_FLAGS")
CPU_MODEL=$(strip "$CPU_MODEL")

selectClocksource() {
  CLOCKSOURCE="tsc"
  [[ "${ARCH,,}" == "arm64" ]] && CLOCKSOURCE="arch_sys_counter"
  CLOCK="/sys/devices/system/clocksource/clocksource0/current_clocksource"
}

checkClocksource() {
  local result

  if [ ! -f "$CLOCK" ]; then
    warn "file \"$CLOCK\" cannot be found?"
    return 0
  fi

  result=$(<"$CLOCK")
  result="${result//[![:print:]]/}"

  case "${result,,}" in
    "${CLOCKSOURCE,,}" ) ;;
    "kvm-clock" ) info "Nested KVM virtualization detected.." ;;
    "hyperv_clocksource_tsc_page" ) info "Nested Hyper-V virtualization detected.." ;;
    "hpet" ) warn "unsupported clock source ﻿detected﻿: '$result'. Please﻿ ﻿set host clock source to '$CLOCKSOURCE'." ;;
    *) warn "unexpected clock source ﻿detected﻿: '$result'. Please﻿ ﻿set host clock source to '$CLOCKSOURCE'." ;;
  esac
}

checkSse42() {
  if ! grep -qw "sse4_2" <<< "$flags"; then
    error "Your CPU does not have the SSE4 instruction set that Virtual DSM requires!"
    ! enabled "$DEBUG" && exit 88
  fi
}

configureKvmCpuModel() {

  CPU_FEATURES="kvm=on,l3-cache=on,+hypervisor"
  KVM_OPTS=",accel=kvm -enable-kvm -global kvm-pit.lost_tick_policy=discard"

  if [ -z "$CPU_MODEL" ]; then
    CPU_MODEL="host"
    CPU_FEATURES+=",migratable=no"
  fi
}

appendKvmInvtscFeature() {
  if grep -qw "svm" <<< "$flags"; then

    # AMD processor
    if grep -qw "tsc_scale" <<< "$flags"; then
      CPU_FEATURES+=",+invtsc"
    fi

  else

    # Intel processor
    local vmx
    vmx=$(sed -ne '/^vmx flags/s/^.*: //p' /proc/cpuinfo)

    if grep -qw "tsc_scaling" <<< "$vmx"; then
      CPU_FEATURES+=",+invtsc"
    fi

  fi
}

configureKvm() {
  configureKvmCpuModel
  checkSse42
  appendKvmInvtscFeature
}

configureTcgCpuModel() {

  if [ -n "$CPU_MODEL" ]; then
    return 0
  fi

  if [[ "$ARCH" == "amd64" ]]; then
    CPU_MODEL="max"
    CPU_FEATURES+=",migratable=no"
  else
    CPU_MODEL="qemu64"
  fi
}

configureTcg() {

  KVM_OPTS=""
  CPU_FEATURES="l3-cache=on,+hypervisor"

  if [[ "$ARCH" == "amd64" ]]; then
    KVM_OPTS=" -accel tcg,thread=multi"
  fi

  configureTcgCpuModel
  CPU_FEATURES+=",+ssse3,+sse4.1,+sse4.2"
}

extractHostCpuArgument() {

  local args prefix suffix param

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
}

composeCpuFlags() {

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
}

configureHostCpuName() {

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
}

selectClocksource
checkClocksource

flags=$(sed -ne '/^flags/s/^.*: //p' /proc/cpuinfo)

if ! disabled "$KVM"; then
  configureKvm
else
  configureTcg
fi

extractHostCpuArgument
composeCpuFlags
configureHostCpuName

return 0
