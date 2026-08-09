#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables
: "${BIOS:=""}"         # BIOS file
: "${SMM:=""}"          # Enable SMM
: "${TPM:=""}"          # Enable TPM
: "${LOGO:=""}"         # Enable logo
: "${CLEAR:=""}"        # Clear NVRAM

BOOT_DESC=""
BOOT_OPTS=""

SWTPM="/run/swtpm"
TPM_PID="/var/run/tpm.pid"
TPM_SOCKET="/tmp/swtpm.sock"

configureBootMode() {

  # Supplying BIOS explicitly overrides BOOT_MODE so the custom firmware path
  # cannot accidentally be combined with an OVMF configuration.
  [ -n "$BIOS" ] && BOOT_MODE="custom"

  case "${BOOT_MODE,,}" in
    "uefi" | "" )

      BOOT_MODE="uefi"

      ROM="OVMF_CODE_4M.fd"
      VARS="OVMF_VARS_4M.fd" ;;

    "secure" )

      BOOT_DESC=" securely"

      if ! isQ35; then
        error "Secure boot requires a Q35 machine!"
        exit 33
      fi

      [ -z "$SMM" ] && SMM="Y"

      ROM="OVMF_CODE_4M.secboot.fd"
      VARS="OVMF_VARS_4M.fd" ;;

    "windows" | "windows_plain" )

      ROM="OVMF_CODE_4M.fd"
      VARS="OVMF_VARS_4M.fd" ;;

    "windows_secure" )

      BOOT_DESC=" securely"

      if ! isQ35; then
        error "Secure boot requires a Q35 machine!"
        exit 33
      fi

      [ -z "$SMM" ] && SMM="Y"
      [ -z "$TPM" ] && TPM="Y"

      ROM="OVMF_CODE_4M.ms.fd"
      VARS="OVMF_VARS_4M.ms.fd" ;;

    "windows_legacy" )

      BOOT_DESC=" (legacy)"

      [ -z "$SMM" ] && SMM="Y"
      [ -z "${HV:-}" ] && HV="N"
      [ -z "${USB:-}" ] && USB="usb-ehci,id=ehci" ;;

    "legacy" )

      BOOT_DESC=" with SeaBIOS" ;;

    "custom" )

      BOOT_DESC=" with custom BIOS file"

      BIOS=$(strip "$BIOS")

      if [ -z "$BIOS" ]; then
        error "BOOT_MODE is custom but BIOS is empty!"
        exit 33
      fi

      BOOT_OPTS="-bios $BIOS" ;;

    *)

      error "Unknown BOOT_MODE, value \"${BOOT_MODE}\" is not recognized!"
      exit 33 ;;

  esac

  return 0
}

addWindowsBootOptions() {

  if [[ "${BOOT_MODE,,}" == "windows"* ]]; then

    # Windows expects a local-time hardware clock, and disabling S3/S4 avoids
    # sleep states that cannot be resumed reliably in this container setup.
    BOOT_OPTS+=" -rtc base=localtime"

    if isQ35; then
      BOOT_OPTS+=" -global ICH9-LPC.disable_s3=1"
      BOOT_OPTS+=" -global ICH9-LPC.disable_s4=1"
    fi

  fi

  return 0
}

clearNvram() {

  # Keep firmware variables and TPM state isolated per boot mode so switching
  # between plain, secure, and legacy configurations cannot mix their state.
  DEST="$STORAGE/${BOOT_MODE,,}"

  if enabled "$CLEAR"; then
    # Clear NVRAM (helps to fix corruptions)
    rm -f "$DEST.rom" "$DEST.vars" "$DEST.tpm"
  fi

  return 0
}

prepareUefiRom() {

  if [ -e "$DEST.rom" ] && [ ! -f "$DEST.rom" ]; then
    error "UEFI boot path \"$DEST.rom\" is not a regular file!"
    exit 44
  fi

  [ -s "$DEST.rom" ] && return 0

  local rom="$OVMF/$ROM"
  [ ! -s "$rom" ] && error "UEFI boot file ($rom) not found!" && exit 44

  local logo="/var/www/img/${PROCESS,,}.bmp"
  [ ! -s "$logo" ] && logo="/var/www/img/qemu.bmp"

  if ! disabled "$LOGO" && [ ! -s "$logo" ]; then
    LOGO="N"
    warn "boot logo file ($logo) not found!"
  fi

  # Build the firmware copy through a temporary file so an interrupted logo
  # patch never replaces the last usable ROM.
  rm -f "$DEST.tmp"

  if ! disabled "$LOGO" &&
     ! /run/boot-logo "$logo" "$rom" --output "$DEST.tmp" -q; then
    warn "failed to add custom logo ($logo) to UEFI firmware!"
    rm -f "$DEST.tmp"
  fi

  if [[ ! -f "$DEST.tmp" ]] && ! cp "$rom" "$DEST.tmp"; then
    rm -f "$DEST.tmp"
    error "Failed to copy UEFI boot file to $DEST.tmp" && exit 44
  fi

  if ! mv "$DEST.tmp" "$DEST.rom"; then
    rm -f "$DEST.tmp"
    error "Failed to move UEFI boot file to $DEST.rom" && exit 44
  fi

  setOwner "$DEST.rom" || warn "failed to set the owner for \"$DEST.rom\" !"

  return 0
}

prepareUefiVars() {

  if [ -e "$DEST.vars" ] && [ ! -f "$DEST.vars" ]; then
    error "UEFI vars path \"$DEST.vars\" is not a regular file!"
    exit 44
  fi

  [ -s "$DEST.vars" ] && return 0

  local vars="$OVMF/$VARS"
  [ ! -s "$vars" ] && error "UEFI vars file ($vars) not found!" && exit 45

  rm -f "$DEST.tmp"

  if ! cp "$vars" "$DEST.tmp"; then
    rm -f "$DEST.tmp"
    error "Failed to copy UEFI vars file to $DEST.tmp" && exit 45
  fi

  if ! mv "$DEST.tmp" "$DEST.vars"; then
    rm -f "$DEST.tmp"
    error "Failed to move UEFI vars file to $DEST.vars" && exit 45
  fi

  setOwner "$DEST.vars" || warn "failed to set the owner for \"$DEST.vars\" !"

  return 0
}

configureUefi() {

  case "${BOOT_MODE,,}" in

    "uefi" | "secure" | "windows" | "windows_plain" | "windows_secure" )

      OVMF="/usr/share/OVMF"

      prepareUefiRom
      prepareUefiVars

      if [[ "${BOOT_MODE,,}" == "secure" || "${BOOT_MODE,,}" == "windows_secure" ]]; then
        BOOT_OPTS+=" -global driver=cfi.pflash01,property=secure,value=on"
      fi

      BOOT_OPTS+=" -drive file=$DEST.rom,if=pflash,unit=0,format=raw,readonly=on"
      BOOT_OPTS+=" -drive file=$DEST.vars,if=pflash,unit=1,format=raw" ;;

  esac

  return 0
}

enableIgnoreMsrs() {

  MSRS="/sys/module/kvm/parameters/ignore_msrs"
  [ ! -e "$MSRS" ] && return 0

  result=$(<"$MSRS")
  result="${result//[![:print:]]/}"

  # This host KVM setting is best-effort: unsupported MSR accesses should not
  # terminate guests, but containers may lack permission to change the module.
  if [[ "$result" == "0" || "${result^^}" == "N" ]]; then
    echo 1 | tee "$MSRS" > /dev/null 2>&1 || true
  fi

  return 0
}

checkClocksource() {

  CLOCKSOURCE="tsc"
  [[ "${ARCH,,}" == "arm64" ]] && CLOCKSOURCE="arch_sys_counter"
  CLOCK="/sys/devices/system/clocksource/clocksource0/current_clocksource"

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
    "hpet" ) warn "unsupported clock source detected: '$result'. Please set host clock source to '$CLOCKSOURCE'." ;;
    *) warn "unexpected clock source detected: '$result'. Please set host clock source to '$CLOCKSOURCE'." ;;
  esac

  return 0
}

detectSmbiosSerial() {

  SM_BIOS=""
  PS="/sys/class/dmi/id/product_serial"

  if [ -r "$PS" ]; then

    # Reuse the host product serial as a stable SMBIOS identity after stripping
    # characters that cannot safely appear in the QEMU argument.
    BIOS_SERIAL=$(<"$PS")
    BIOS_SERIAL="${BIOS_SERIAL//[![:alnum:]]/}"

    if [ -n "$BIOS_SERIAL" ]; then
      SM_BIOS="-smbios type=1,serial=$BIOS_SERIAL"
    fi

  fi

  return 0
}

stopTpm() {

  local pid=""

  if readPidFile pid "$TPM_PID" && isAlive "$pid"; then
    pKill "$pid" 2

    if isAlive "$pid"; then
      kill -9 -- "$pid" 2>/dev/null || :
    fi
  fi

  rm -f "$TPM_PID" "$TPM_SOCKET"
  return 0
}

startTpm() {

  if ! enabled "$TPM"; then
    return 0
  fi

  local msg="Starting TPM emulator..."
  enabled "$DEBUG" && echo "$msg"

  # Workaround to circumvent AppArmor profile
  if [ ! -x "$SWTPM" ]; then
    if ! cp /usr/bin/swtpm "$SWTPM"; then
      error "Failed to copy TPM emulator, disabling TPM."
      return 0
    fi
  fi

  local rc

  if "$SWTPM" socket -t -d --tpm2 \
      --tpmstate "backend-uri=file://$DEST.tpm" \
      --ctrl "type=unixio,path=$TPM_SOCKET" \
      --pid "file=$TPM_PID"; then
    rc=0
  else
    rc=$?
  fi

  # TPM is optional. Failure disables it for this run instead of preventing the
  # virtual machine from booting.
  if (( rc != 0 )); then
    stopTpm
    error "Failed to start TPM emulator, reason: $rc"
    return 0
  fi

  local i
  local pid=""

  for (( i = 1; i < 25; i++ )); do

    if readPidFile pid "$TPM_PID"; then
      if [ -S "$TPM_SOCKET" ] && isAlive "$pid"; then
        BOOT_OPTS+=" -chardev socket,id=chrtpm,path=$TPM_SOCKET"
        BOOT_OPTS+=" -tpmdev emulator,id=tpm0,chardev=chrtpm"
        BOOT_OPTS+=" -device tpm-tis,tpmdev=tpm0"
        return 0
      fi

      if ! isAlive "$pid"; then
        break
      fi
    fi

    if (( i % 5 == 0 )); then
      echo "Waiting for TPM emulator to launch..."
    fi

    sleep 0.25

  done

  stopTpm
  error "TPM socket ($TPM_SOCKET) not found? Disabling TPM module..."

  return 0
}

msg="Configuring boot..."

html "$msg"
enabled "$DEBUG" && echo "$msg"

configureBootMode

# Apply default settings
[ -z "$SMM" ] && SMM="N"
[ -z "$TPM" ] && TPM="N"

addWindowsBootOptions

clearNvram
stopTpm

configureUefi
enableIgnoreMsrs
checkClocksource
detectSmbiosSerial

startTpm

return 0
