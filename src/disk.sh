#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables

: "${DISK_IO:="native"}"          # I/O Mode, can be set to 'native', 'threads' or 'io_uring'
: "${DISK_FMT:="raw"}"            # Disk file format, 'raw' by default for best performance
: "${DISK_TYPE:=""}"              # Device type to be used, "sata", "nvme", "blk" or "scsi"
: "${DISK_FLAGS:=""}"             # Specifies the options for use with the qcow2 disk format
: "${DISK_CACHE:="none"}"         # Caching mode, can be set to 'writeback' for better performance
: "${DISK_DISCARD:="unmap"}"      # Controls whether unmap (TRIM) commands are passed to the host.
: "${DISK_ROTATION:="1"}"         # Rotation rate, set to 1 for SSD storage and increase for HDD

# Sanitize all variables
DISK_IO=$(strip "$DISK_IO")
DISK_FMT=$(strip "$DISK_FMT")
DISK_TYPE=$(strip "$DISK_TYPE")
DISK_FLAGS=$(strip "$DISK_FLAGS")
DISK_CACHE=$(strip "$DISK_CACHE")
DISK_DISCARD=$(strip "$DISK_DISCARD")
DISK_ROTATION=$(strip "$DISK_ROTATION")

BOOT="$STORAGE/$BASE.boot.img"
SYSTEM="$STORAGE/$BASE.system.img"

[ ! -s "$BOOT" ] && error "Virtual DSM boot-image does not exist ($BOOT)" && exit 81
[ ! -s "$SYSTEM" ] && error "Virtual DSM system-image does not exist ($SYSTEM)" && exit 82

if ! setOwner "$BOOT"; then
  warn "failed to set the owner for \"$BOOT\" !"
fi

if ! setOwner "$SYSTEM"; then
  warn "failed to set the owner for \"$SYSTEM\" !"
fi

fmt2ext() {
  local diskFmt="$1"

  case "${diskFmt,,}" in
    qcow2) echo "qcow2" ;;
    raw) echo "img" ;;
    *) error "Unrecognized disk format: $diskFmt" && exit 78 ;;
  esac
}

ext2fmt() {
  local diskExt="$1"

  case "${diskExt,,}" in
    qcow2) echo "qcow2" ;;
    img) echo "raw" ;;
    *) error "Unrecognized file extension: .$diskExt" && exit 78 ;;
  esac
}

getSize() {

  local diskFile="$1"
  local diskExt diskFmt size

  diskExt=$(echo "${diskFile//*./}" | sed 's/^.*\.//')
  diskFmt=$(ext2fmt "$diskExt")

  case "${diskFmt,,}" in
    raw)
      stat -c%s "$diskFile"
      ;;

    qcow2)
      size=$(qemu-img info --output=json -f "$diskFmt" "$diskFile" | jq -r '."virtual-size" // empty')
      if [[ ! "$size" =~ ^[0-9]+$ ]]; then
        error "Failed to determine virtual size of $diskFile"
        exit 78
      fi
      echo "$size"
      ;;

    *)
      error "Unrecognized disk format: $diskFmt"
      exit 78
      ;;
  esac
}

isCow() {
  local fs="$1"

  if [[ "${fs,,}" == "btrfs" ]]; then
    return 0
  fi

  return 1
}

supportsDirect() {
  local fs="$1"

  if [[ "${fs,,}" == "ecryptfs" || "${fs,,}" == "tmpfs" ]]; then
    return 1
  fi

  return 0
}

validDiskType() {

  case "${1,,}" in
    "ide" | "sata" | "nvme" | "usb" | "scsi" | "blk" | \
    "virtio-blk" | "virtio-scsi" | "auto" | "none" )
      return 0
      ;;
  esac

  return 1
}

allocateRaw() {

  local diskFile="$1"
  local dataSize="$2"

  if disabled "$ALLOCATE"; then
    truncate -s "$dataSize" "$diskFile"
    return $?
  fi

  fallocate -l "$dataSize" "$diskFile" &>/dev/null && return 0
  fallocate -l -x "$dataSize" "$diskFile" && return 0
  truncate -s "$dataSize" "$diskFile" || return 1

  return 0
}

getDiskOptions() {

  local fs="$1"
  local diskFmt="$2"
  local diskParam="$DISK_ALLOC"

  isCow "$fs" && diskParam+=",nocow=on"

  if [[ "${diskFmt,,}" != "raw" ]]; then
    [ -n "$DISK_FLAGS" ] && diskParam+=",$DISK_FLAGS"
  fi

  echo "$diskParam"
  return 0
}

normalizeSize() {

  local diskSpace="$1"
  local diskDesc="$2"
  local dir="$3"

  local gb free space
  local dataSize spare=1073741824

  if [[ "${diskSpace,,}" == "max" || "${diskSpace,,}" == "half" ]]; then

    free=$(df --output=avail -B 1 "$dir" | tail -n 1)

    if [[ "${diskSpace,,}" == "max" ]]; then
      free=$(( free - spare ))
    else
      free=$(( free / 2 ))
    fi

    (( free < spare )) && free="$spare"
    gb=$(( free / 1073741825 ))
    diskSpace="${gb}G"

  fi

  space="${diskSpace// /}"
  [ -z "$space" ] && space="256G"
  [ -z "${space//[0-9. ]}" ] && space="${space}G"
  space=$(echo "${space^^}" | sed 's/MB/M/g;s/GB/G/g;s/TB/T/g')

  if ! numfmt --from=iec "$space" &>/dev/null; then
    error "Invalid value for ${diskDesc^^}_SIZE: $diskSpace" && exit 73
  fi

  dataSize=$(numfmt --from=iec "$space")

  if (( dataSize < 6442450944 )); then
    error "Please increase the ${diskDesc^^}_SIZE variable to at least 6 GB." && exit 73
  fi

  echo "$space"
  return 0
}

baseDir() {

  local path="${1%/}"

  [[ -z "$path" || "$path" == "/" ]] && {
    echo "/"
    return 0
  }

  path="${path#/}"
  path="${path%%/*}"

  echo "/$path"
  return 0
}

freeSpace() {

  local path="$1"

  local base
  base=$(baseDir "$path")

  if ! available=$(df --output=avail -B 1 "$path" | tail -n 1); then
    error "Failed to check free space in $base."
    exit 76
  fi

  if [[ ! "$available" =~ ^[0-9]+$ ]]; then
    error "Failed to check free space in $base."
    exit 76
  fi

  return 0
}

createDisk() {

  local diskFile="$1"
  local diskSpace="$2"
  local diskDesc="$3"
  local diskFmt="$4"
  local fs="$5"

  local gb dir base
  local attributes available

  rm -f "$diskFile"

  local dataSize
  dataSize=$(numfmt --from=iec "$diskSpace")

  if ! disabled "$ALLOCATE"; then

    # Check free diskspace
    dir=$(dirname "$diskFile")
    base=$(baseDir "$dir")

    freeSpace "$dir"

    if (( dataSize > available )); then
      gb=$(formatBytes "$available")
      error "Not enough free space to create a $diskDesc of ${diskSpace/G/ GB} in $base, it has only $gb available..."
      error "Please specify a smaller ${diskDesc^^}_SIZE or disable preallocation by setting ALLOCATE=N." && exit 76
    fi

  fi

  html "Creating a $diskDesc image..."
  info "Creating a ${diskSpace/G/ GB} $DISK_STYLE $diskDesc image in $diskFmt format..."

  local failure="Could not create a $DISK_STYLE $diskFmt $diskDesc image of ${diskSpace/G/ GB} ($diskFile)"

  case "${diskFmt,,}" in
    raw)

      if isCow "$fs"; then
        if ! touch "$diskFile"; then
          error "$failure" && exit 77
        fi
        { chattr +C "$diskFile"; } || :
      fi

      if ! allocateRaw "$diskFile" "$dataSize"; then
        rm -f "$diskFile"
        error "$failure" && exit 77
      fi
      ;;
    qcow2)

      local diskParam
      diskParam=$(getDiskOptions "$fs" "$diskFmt")

      if ! qemu-img create -f "$diskFmt" -o "$diskParam" -- "$diskFile" "$dataSize" ; then
        rm -f "$diskFile"
        error "$failure" && exit 70
      fi
      ;;
  esac

  if isCow "$fs"; then
    attributes=$(lsattr "$diskFile")
    if [[ "$attributes" != *"C"* ]]; then
      error "Failed to disable COW for $diskDesc image $diskFile on ${fs^^} filesystem (returned $attributes)"
    fi
  fi

  return 0
}

resizeDisk() {

  local diskFile="$1"
  local diskSpace="$2"
  local diskDesc="$3"
  local diskFmt="$4"
  local fs="$5"

  local gb dir base dataSize
  local available currentSize

  currentSize=$(getSize "$diskFile") || exit 71
  dataSize=$(numfmt --from=iec "$diskSpace")
  local required=$(( dataSize - currentSize ))
  (( required < 1 )) && error "Shrinking disks is not supported yet, please increase ${diskDesc^^}_SIZE." && exit 71

  if ! disabled "$ALLOCATE"; then

    # Check free diskspace
    dir=$(dirname "$diskFile")
    base=$(baseDir "$dir")

    freeSpace "$dir"

    if (( required > available )); then
      gb=$(formatBytes "$available")
      error "Not enough free space to resize $diskDesc to ${diskSpace/G/ GB} in $base, it has only $gb available.."
      error "Please specify a smaller ${diskDesc^^}_SIZE or disable preallocation by setting ALLOCATE=N." && exit 74
    fi

  fi

  gb=$(formatBytes "$currentSize")
  MSG="Resizing $diskDesc from $gb to ${diskSpace/G/ GB}..."
  info "$MSG" && html "$MSG"

  local failure="Could not resize the $DISK_STYLE $diskFmt $diskDesc image from ${gb} to ${diskSpace/G/ GB} ($diskFile)"

  case "${diskFmt,,}" in
    raw)

      if ! allocateRaw "$diskFile" "$dataSize"; then
        error "$failure" && exit 75
      fi
      ;;
    qcow2)

      if ! qemu-img resize -f "$diskFmt" "--$DISK_ALLOC" "$diskFile" "$dataSize" ; then
        error "$failure" && exit 72
      fi

      ;;
  esac

  return 0
}

convertDisk() {

  local sourceFile="$1"
  local sourceFmt="$2"
  local destinationFile="$3"
  local destinationFmt="$4"
  local diskBase="$5"
  local diskDesc="$6"
  local fs="$7"
  local tmpFile="$diskBase.tmp"

  local gb dir base attributes
  local available currentSize

  [ -f "$destinationFile" ] && error "Conversion failed, destination file $destinationFile already exists?" && exit 79
  [ ! -f "$sourceFile" ] && error "Conversion failed, source file $sourceFile does not exist?" && exit 79

  rm -f "$tmpFile"

  dir=$(dirname "$tmpFile")
  base=$(baseDir "$dir")

  if ! disabled "$ALLOCATE"; then

    # Check free diskspace
    currentSize=$(getSize "$sourceFile") || exit 79

    freeSpace "$dir"

    if (( currentSize > available )); then
      gb=$(formatBytes "$available")
      error "Not enough free space to convert $diskDesc to $destinationFmt in $base, it has only $gb available..."
      error "Please free up some disk space or disable preallocation by setting ALLOCATE=N." && exit 76
    fi

  fi

  local msg="Converting $diskDesc to $destinationFmt"
  html "$msg..."
  info "$msg, please wait until completed..."

  local convertFlags="-p"
  local diskParam
  diskParam=$(getDiskOptions "$fs" "$destinationFmt")

  if [[ "$destinationFmt" != "raw" ]]; then
    if disabled "$ALLOCATE"; then
      convertFlags+=" -c"
    fi
  fi

  # shellcheck disable=SC2086
  if ! qemu-img convert -f "$sourceFmt" $convertFlags -o "$diskParam" -O "$destinationFmt" -- "$sourceFile" "$tmpFile"; then
    rm -f "$tmpFile"
    error "Failed to convert $DISK_STYLE $diskDesc image to $destinationFmt format in $base, is there enough space available?" && exit 79
  fi

  if [[ "$destinationFmt" == "raw" ]]; then
    if ! disabled "$ALLOCATE"; then

      # Work around qemu-img bug
      if ! currentSize=$(stat -c%s "$tmpFile"); then
        error "Failed to determine converted image size: $tmpFile"
        exit 79
      fi

      if ! fallocate -l "$currentSize" "$tmpFile" &>/dev/null; then
        if ! fallocate -l -x "$currentSize" "$tmpFile"; then
          error "Failed to allocate $currentSize bytes for $diskDesc image $tmpFile"
        fi
      fi
    fi
  fi

  if ! mv "$tmpFile" "$destinationFile"; then
    error "Failed to move converted $diskDesc image to $destinationFile."
    exit 79
  fi

  if ! rm -f "$sourceFile"; then
    error "Failed to remove old $diskDesc image $sourceFile."
    exit 79
  fi

  if isCow "$fs"; then
    attributes=$(lsattr "$destinationFile")
    if [[ "$attributes" != *"C"* ]]; then
      error "Failed to disable COW for $diskDesc image $destinationFile on ${fs^^} filesystem (returned $attributes)"
    fi
  fi

  msg="Conversion of $diskDesc"
  info "$msg to $destinationFmt completed successfully!"

  return 0
}

checkFS () {

  local fs="$1"
  local diskFile="$2"
  local diskDesc="$3"

  local dir base
  local attributes

  dir=$(dirname "$diskFile")
  base=$(baseDir "$dir")
  [ ! -d "$dir" ] && return 0

  if [[ "${fs,,}" == "overlay"* && "${ENGINE,,}" == "docker" ]]; then
    warn "the filesystem of $base is OverlayFS, this usually means it was binded to an invalid path!"
  fi

  if [[ "${fs,,}" == "fuse"* ]]; then
    warn "the filesystem of $base is FUSE, this extra layer will negatively affect performance!"
  fi

  if ! supportsDirect "$fs"; then
    warn "the filesystem of $base is $fs, which does not support O_DIRECT mode, adjusting settings..."
  fi

  if isCow "$fs"; then
    if [ -f "$diskFile" ]; then
      attributes=$(lsattr "$diskFile")
      if [[ "$attributes" != *"C"* ]]; then
        warn "COW (copy on write) is not disabled for $diskDesc image file $diskFile, this is recommended on ${fs^^} filesystems!"
      fi
    fi
  fi

  return 0
}

createDevice () {

  local diskFile="$1"
  local diskType="$2"
  local diskIndex="$3"
  local diskAddress="$4"
  local diskFmt="$5"
  local diskIo="$6"
  local diskCache="$7"
  local diskSerial="$8"
  local diskSectors="$9"
  local bus="${PCI_BUS:-pcie.0}"

  [[ -z "${PCI_BUS:-}" && ( "${MACHINE,,}" == pc || "${MACHINE,,}" == pc-i440fx* ) ]] && bus="pci.0"

  local bootIndex=""
  local diskId="data$diskIndex"
  [ -n "$diskIndex" ] && bootIndex=",bootindex=$diskIndex"
  local result=" -drive file=$diskFile,id=$diskId,format=$diskFmt,cache=$diskCache,aio=$diskIo,discard=$DISK_DISCARD,detect-zeroes=on"

  case "${diskType,,}" in
    "none" ) ;;
    "auto" )
      echo "$result"
      ;;
    "usb" )
      result+=",if=none \
      -device usb-storage,drive=${diskId}${bootIndex}${diskSerial}${diskSectors}"
      echo "$result"
      ;;
    "nvme" )
      result+=",if=none \
      -device nvme,drive=${diskId}${bootIndex},serial=deadbeaf${diskIndex}${diskSerial}${diskSectors}"
      echo "$result"
      ;;
    "ide" | "sata" )
      result+=",if=none \
      -device ich9-ahci,id=ahci${diskIndex},addr=$diskAddress \
      -device ide-hd,drive=${diskId},bus=ahci$diskIndex.0,rotation_rate=$DISK_ROTATION${bootIndex}${diskSerial}${diskSectors}"
      echo "$result"
      ;;
    "blk" | "virtio-blk" )
      result+=",if=none \
      -device virtio-blk-pci,drive=${diskId},bus=$bus,addr=$diskAddress,iothread=io2${bootIndex}${diskSerial}${diskSectors}"
      echo "$result"
      ;;
    "scsi" | "virtio-scsi" )
      result+=",if=none \
      -device virtio-scsi-pci,id=${diskId}b,bus=$bus,addr=$diskAddress,iothread=io2,hotplug=off \
      -device scsi-hd,drive=${diskId},bus=${diskId}b.0,channel=0,scsi-id=0,lun=0,rotation_rate=$DISK_ROTATION${bootIndex}${diskSerial}${diskSectors}"
      echo "$result"
      ;;
  esac

  return 0
}

finishDisks () {

  case "${DISK_TYPE,,}" in
    "blk" | "scsi" | "virtio-blk" | "virtio-scsi" )
      [[ "$DISK_OPTS" != *" -object iothread,id=io2"* ]] && DISK_OPTS+=" -object iothread,id=io2" ;;
  esac

  return 0
}

addDisk () {

  local diskBase="$1"
  local diskType="$2"
  local diskDesc="$3"
  local diskSpace="$4"
  local diskIndex="$5"
  local diskAddress="$6"
  local diskFmt="$7"
  local diskIo="$8"
  local diskCache="$9"

  local fs dir used space
  local diskExt diskFile
  local dataSize missing
  local available currentSize
  local previousExt previousFmt

  diskExt=$(fmt2ext "$diskFmt")
  diskFile="$diskBase.$diskExt"

  dir=$(dirname "$diskFile")
  [ ! -d "$dir" ] && return 0

  space=$(normalizeSize "$diskSpace" "$diskDesc" "$dir")
  dataSize=$(numfmt --from=iec "$space")

  fs=$(stat -f -c %T "$dir")
  checkFS "$fs" "$diskFile" "$diskDesc" || exit $?

  if ! supportsDirect "$fs"; then
    diskIo="threads"
    diskCache="writeback"
  fi

  if [ ! -s "$diskFile" ] ; then

    if [[ "${diskFmt,,}" != "raw" ]]; then
      previousFmt="raw"
    else
      previousFmt="qcow2"
    fi

    previousExt=$(fmt2ext "$previousFmt")

    if [ -s "$diskBase.$previousExt" ] ; then
      convertDisk "$diskBase.$previousExt" "$previousFmt" "$diskFile" "$diskFmt" "$diskBase" "$diskDesc" "$fs" || exit $?
    fi

  fi

  if [ -s "$diskFile" ]; then

    currentSize=$(getSize "$diskFile") || exit 71

    if (( dataSize > currentSize )); then

      resizeDisk "$diskFile" "$space" "$diskDesc" "$diskFmt" "$fs" || exit $?

    else

      if (( dataSize < currentSize )); then

        if [[ "${diskSpace,,}" != "max" && "${diskSpace,,}" != "half" ]]; then
          info "You decreased the ${diskDesc^^}_SIZE variable to ${diskSpace/G/ GB} but shrinking disks is not supported, will be ignored..."
        fi

      fi
    fi

  else

    createDisk "$diskFile" "$space" "$diskDesc" "$diskFmt" "$fs" || exit $?

  fi

  if [ -f "$diskFile" ] && disabled "$ALLOCATE"; then

    currentSize=$(getSize "$diskFile") || exit 73
    used=$(du -sB 1 "$diskFile" | cut -f1)
    available=$(df --output=avail -B 1 "$dir" | tail -n 1)
    missing=$(( currentSize - used - available ))
    (( missing < 0 )) && missing=0

    if (( missing > 0 )); then

      local gb base msg

      gb=$(formatBytes "$available")
      base=$(baseDir "$dir")
      missing=$(formatBytes "$missing")
      currentSize=$(formatBytes "$currentSize")
      msg="The virtual size of the ${diskDesc,,} is $currentSize"

      if [ -n "$used" ] && [[ "$used" != "0" ]]; then
        used=$(formatBytes "$used")
        msg+=" (of which $used is used)"
      fi

      info "$msg, but there is only $gb of free space remaining in $base now."
      info "Please consider making at least $missing more space available in $base for future expansions."

    fi
  fi

  if [ -f "$diskFile" ]; then
    if ! setOwner "$diskFile"; then
      warn "failed to set the owner for \"$diskFile\" !"
    fi
  fi

  DISK_OPTS+=$(createDevice "$diskFile" "$diskType" "$diskIndex" "$diskAddress" "$diskFmt" "$diskIo" "$diskCache" "" "")

  return 0
}

addDevice () {

  local diskDev="$1"
  local diskType="$2"
  local diskIndex="$3"
  local diskAddress="$4"

  local sectors=""
  local devType
  devType=$(lsblk -no TYPE "$diskDev" 2>/dev/null | head -n1)

  [ -z "$diskDev" ] && return 0
  [ ! -b "$diskDev" ] && error "Device $diskDev cannot be found! Please add it to the 'devices' section of your compose file." && exit 55

  # Only detect and apply sector sizes for partitions, not whole disks.
  # Whole disk passthrough with explicit sector sizes causes DSM not to recognize the disk.
  if [[ "$devType" == "part" ]]; then

    local result
    local logical="" physical=""

    result=$(fdisk -l "$diskDev" 2>/dev/null | grep -m 1 -o "(logical/physical): .*" | cut -c 21- || true)

    if [ -n "$result" ]; then
      logical="${result%% *}"
      physical=$(echo "$result" | grep -m 1 -o "/ .*" | cut -c 3- || true)
      physical="${physical%% *}"
    fi

    if [ -z "$logical" ] || [ -z "$physical" ]; then
      warn "Failed to determine the sector size for $diskDev"
    elif [[ "$physical" != "512" ]]; then
      sectors=",logical_block_size=$logical,physical_block_size=$physical"
    fi

  fi

  DISK_OPTS+=$(createDevice "$diskDev" "$diskType" "$diskIndex" "$diskAddress" "raw" "$DISK_IO" "$DISK_CACHE" "" "$sectors")

  return 0
}

[ -z "${DISK_OPTS:-}" ] && DISK_OPTS=""
[ -z "${DISK_TYPE:-}" ] && DISK_TYPE="scsi"
[ -z "${DISK_NAME:-}" ] && DISK_NAME="data"
[ -z "${DISK_DISABLE:-}" ] && DISK_DISABLE=""

if ! enabled "$DISK_DISABLE"; then
  msg="Initializing disks..."
  enabled "$DEBUG" && echo "$msg"
fi

if [[ "${DISK_IO,,}" == "native" && "${DISK_CACHE,,}" != "none" && "${DISK_CACHE,,}" != "directsync" ]]; then
  warn "DISK_IO=native requires direct I/O caching, using DISK_IO=threads with DISK_CACHE=$DISK_CACHE."
  DISK_IO="threads"
fi

case "${DISK_DISCARD,,}" in
  "y" | "yes" | "true" | "1" | "on" | "unmap" )
    DISK_DISCARD="unmap" ;;

  "n" | "no" | "false" | "0" | "off" | "ignore" )
    DISK_DISCARD="ignore" ;;

  * )
    warn "Invalid DISK_DISCARD value '$DISK_DISCARD', using 'unmap'."
    DISK_DISCARD="unmap" ;;
esac

if [[ ! "$DISK_ROTATION" =~ ^[0-9]+$ ]]; then
  warn "Invalid DISK_ROTATION value '$DISK_ROTATION', using 1."
  DISK_ROTATION="1"
fi

DISK_FMT="${DISK_FMT,,}"

case "$DISK_FMT" in
  "raw" | "qcow2" ) ;;
  * ) error "Invalid DISK_FMT specified, value \"$DISK_FMT\" is not recognized!" && exit 78 ;;
esac

if ! validDiskType "$DISK_TYPE"; then
  error "Invalid DISK_TYPE specified, value \"$DISK_TYPE\" is not recognized!"
  exit 80
fi

if [[ "$DISK_FLAGS" =~ [[:space:]] ]]; then
  error "Invalid DISK_FLAGS value '$DISK_FLAGS', spaces are not allowed."
  exit 78
fi

if [ -z "$ALLOCATE" ]; then
  ALLOCATE="N"
fi

if disabled "$ALLOCATE"; then
  DISK_STYLE="growable"
  DISK_ALLOC="preallocation=off"
else
  DISK_STYLE="preallocated"
  DISK_ALLOC="preallocation=falloc"
fi

DISK_OPTS+=$(createDevice "$BOOT" "$DISK_TYPE" "1" "0xa" "raw" "$DISK_IO" "$DISK_CACHE" "" "")
DISK_OPTS+=$(createDevice "$SYSTEM" "$DISK_TYPE" "2" "0xb" "raw" "$DISK_IO" "$DISK_CACHE" "" "")

if enabled "$DISK_DISABLE"; then
  finishDisks && return 0
fi

DISK1_FILE="$STORAGE/${DISK_NAME}"
DISK2_FILE="/storage2/${DISK_NAME}2"
DISK3_FILE="/storage3/${DISK_NAME}3"
DISK4_FILE="/storage4/${DISK_NAME}4"

: "${DISK2_SIZE:=""}"
: "${DISK3_SIZE:=""}"
: "${DISK4_SIZE:=""}"

: "${DEVICE:=""}"        # Docker variables to passthrough a block device, like /dev/vdc1.
: "${DEVICE2:=""}"
: "${DEVICE3:=""}"
: "${DEVICE4:=""}"

[ -z "$DEVICE" ] && [ -b "/disk" ] && DEVICE="/disk"
[ -z "$DEVICE" ] && [ -b "/disk1" ] && DEVICE="/disk1"
[ -z "$DEVICE2" ] && [ -b "/disk2" ] && DEVICE2="/disk2"
[ -z "$DEVICE3" ] && [ -b "/disk3" ] && DEVICE3="/disk3"
[ -z "$DEVICE4" ] && [ -b "/disk4" ] && DEVICE4="/disk4"

[ -z "$DEVICE" ] && [ -b "/dev/disk1" ] && DEVICE="/dev/disk1"
[ -z "$DEVICE2" ] && [ -b "/dev/disk2" ] && DEVICE2="/dev/disk2"
[ -z "$DEVICE3" ] && [ -b "/dev/disk3" ] && DEVICE3="/dev/disk3"
[ -z "$DEVICE4" ] && [ -b "/dev/disk4" ] && DEVICE4="/dev/disk4"

DISK_FILES=( "$DISK1_FILE" "$DISK2_FILE" "$DISK3_FILE" "$DISK4_FILE" )
DISK_DESCS=( "disk" "disk2" "disk3" "disk4" )
DISK_SIZES=( "$DISK_SIZE" "$DISK2_SIZE" "$DISK3_SIZE" "$DISK4_SIZE" )
DISK_DEVICES=( "$DEVICE" "$DEVICE2" "$DEVICE3" "$DEVICE4" )
DISK_INDEXES=( "3" "4" "5" "6" )
DISK_ADDRESSES=( "0xc" "0xd" "0xe" "0xf" )

for i in "${!DISK_FILES[@]}"; do

  if [ -n "${DISK_DEVICES[i]}" ]; then
    addDevice "${DISK_DEVICES[i]}" "$DISK_TYPE" "${DISK_INDEXES[i]}" "${DISK_ADDRESSES[i]}" || exit $?
  else
    addDisk "${DISK_FILES[i]}" "$DISK_TYPE" "${DISK_DESCS[i]}" "${DISK_SIZES[i]}" "${DISK_INDEXES[i]}" "${DISK_ADDRESSES[i]}" "$DISK_FMT" "$DISK_IO" "$DISK_CACHE" || exit $?
  fi

done

finishDisks

return 0
