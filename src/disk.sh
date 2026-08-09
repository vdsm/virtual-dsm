#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables

: "${DISK_IO:=""}"                # I/O Mode, can be set to 'native', 'threads' or 'io_uring'
: "${DISK_FMT:=""}"               # Disk file format, can be set to "raw" (default) or "qcow2"
: "${DISK_TYPE:=""}"              # Device type to be used, "sata", "nvme", "blk" or "scsi"
: "${DISK_FLAGS:=""}"             # Specifies the options for use with the qcow2 disk format
: "${DISK_OFFSET:=""}"            # Number of disk slots to reserve from the PCI address range
: "${DISK_MINIMUM:=""}"           # Require the primary data disk to have at least this size
: "${DISK_OPTIONS:=""}"           # Specifies additional options for the QEMU disk device
: "${DISK_CACHE:="none"}"         # Caching mode, can be set to 'writeback' for better performance
: "${DISK_DISCARD:="unmap"}"      # Controls whether unmap (TRIM) commands are passed to the host.
: "${DISK_ROTATION:="1"}"         # Rotation rate, set to 1 for SSD storage and increase for HDD

# Sanitize all variables
DISK_IO=$(strip "$DISK_IO")
DISK_FMT=$(strip "$DISK_FMT")
DISK_TYPE=$(strip "$DISK_TYPE")
DISK_CACHE=$(strip "$DISK_CACHE")
DISK_FLAGS=$(strip "$DISK_FLAGS")
DISK_OFFSET=$(strip "$DISK_OFFSET")
DISK_MINIMUM=$(strip "$DISK_MINIMUM")
DISK_OPTIONS=$(strip "$DISK_OPTIONS")
DISK_DISCARD=$(strip "$DISK_DISCARD")
DISK_ROTATION=$(strip "$DISK_ROTATION")

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

  # Prefer normal preallocation, then keep-size allocation, and finally a sparse
  # truncate so filesystems with limited fallocate support can still work.
  fallocate -l "$dataSize" "$diskFile" &>/dev/null && return 0
  fallocate -l -x "$dataSize" "$diskFile" && return 0
  truncate -s "$dataSize" "$diskFile" || return 1

  return 0
}

getDiskOptions() {

  local fs="$1"
  local diskFmt="$2"
  local diskParam="$DISK_ALLOC"

  # qcow2 on a copy-on-write filesystem would otherwise add a second COW layer;
  # request NOCOW for the image when the backend supports it.
  isCow "$fs" && diskParam+=",nocow=on"

  if [[ "${diskFmt,,}" != "raw" ]]; then
    [ -n "$DISK_FLAGS" ] && diskParam+=",$DISK_FLAGS"
  fi

  echo "$diskParam"
  return 0
}

normalizeDiskSize() {

  local diskSpace="$1"
  local dir="$2"

  local spare=1073741824 free

  diskSpace="${diskSpace// /}"

  # Dynamic sizes are based on current free space. max leaves a 1 GiB reserve,
  # while half intentionally consumes only half of what is available.
  if [[ "${diskSpace,,}" == "max" || "${diskSpace,,}" == "half" ]]; then

    free=$(df --output=avail -B 1 "$dir" | tail -n 1)

    if [[ "${diskSpace,,}" == "max" ]]; then
      free=$(( free - spare ))
    else
      free=$(( free / 2 ))
    fi

    (( free < spare )) && free="$spare"
    local gb=$(( free / 1073741825 ))
    diskSpace="${gb}G"

  fi

  [ -z "${diskSpace//[0-9. ]}" ] && diskSpace="${diskSpace}G"
  diskSpace=$(echo "${diskSpace^^}" | sed 's/MB/M/g;s/GB/G/g;s/TB/T/g')

  echo "$diskSpace"
  return 0
}

normalizeSize() {

  local diskSpace="$1"
  local diskDesc="$2"
  local dir="$3"

  local space minimum
  local dataSize minimumSize

  diskSpace="${diskSpace// /}"
  [ -z "$diskSpace" ] && diskSpace="${DISK_SIZE// /}"

  space=$(normalizeDiskSize "$diskSpace" "$dir")

  if [[ "$diskDesc" == "disk" ]]; then
    minimum=$(normalizeDiskSize "$DISK_MINIMUM" "$dir")
  else
    minimum="100M"
  fi

  if ! numfmt --from=iec "$space" &>/dev/null; then
    error "Invalid value for ${diskDesc^^}_SIZE: $diskSpace" && exit 73
  fi

  if ! numfmt --from=iec "$minimum" &>/dev/null; then
    error "Invalid value for DISK_MINIMUM: $DISK_MINIMUM" && exit 73
  fi

  dataSize=$(numfmt --from=iec "$space")
  minimumSize=$(numfmt --from=iec "$minimum")

  if (( dataSize < minimumSize )); then
    error "Please increase the ${diskDesc^^}_SIZE variable to at least $(formatBytes "$minimumSize")."
    exit 73
  fi

  echo "$space"
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

      # The NOCOW attribute must be applied before allocating a raw file; setting
      # it after blocks exist would not disable COW for those blocks.
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
  # Convert into a sibling temporary file and replace the source only after the
  # destination is complete, preventing a failed conversion from losing the disk.
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

      # qemu-img may leave converted raw output sparse despite requested
      # preallocation, so allocate its final length explicitly afterward.
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

  # Publish the converted image before deleting the original so a failed
  # conversion or rename never destroys the only usable disk.
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
      error "Failed to disable COW for $diskDesc image $destinationFile on ${fs^^} filesystems (returned $attributes)"
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

  # Filesystems without O_DIRECT support require threaded I/O and writeback
  # caching; native AIO with cache=none would fail at runtime.
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

  local bus
  bus=$(getPciBus)

  local options=""
  [ -n "$DISK_OPTIONS" ] && options=",${DISK_OPTIONS#,}"

  local bootIndex=""
  local diskId="${10:-data$diskIndex}"
  [ -n "$diskIndex" ] && bootIndex=",bootindex=$diskIndex"
  local result=" -drive file=$diskFile,id=$diskId,format=$diskFmt,cache=$diskCache,aio=$diskIo,discard=$DISK_DISCARD,detect-zeroes=on"

  case "${diskType,,}" in
    "none" ) ;;
    "auto" )
      echo "$result"
      ;;
    "usb" )
      result+=",if=none \
      -device usb-storage,drive=${diskId}${bootIndex}${diskSerial}${diskSectors}${options}"
      echo "$result"
      ;;
    "nvme" )
      result+=",if=none \
      -device nvme,drive=${diskId}${bootIndex},serial=${diskId}${diskSerial}${diskSectors}${options}"
      echo "$result"
      ;;
    "ide" | "sata" )
      result+=",if=none \
      -device ich9-ahci,id=ahci${diskIndex},addr=$diskAddress \
      -device ide-hd,drive=${diskId},bus=ahci$diskIndex.0,rotation_rate=$DISK_ROTATION${bootIndex}${diskSerial}${diskSectors}${options}"
      echo "$result"
      ;;
    "blk" | "virtio-blk" )
      result+=",if=none \
      -device virtio-blk-pci,drive=${diskId},bus=$bus,addr=$diskAddress${IOTHREAD_OPT}${bootIndex}${diskSerial}${diskSectors}${options}"
      echo "$result"
      ;;
    "scsi" | "virtio-scsi" )
      result+=",if=none \
      -device virtio-scsi-pci,id=${diskId},bus=$bus,addr=$diskAddress${IOTHREAD_OPT},hotplug=off \
      -device scsi-hd,drive=${diskId},bus=${diskId}.0,channel=0,scsi-id=0,lun=0,rotation_rate=$DISK_ROTATION${bootIndex}${diskSerial}${diskSectors}${options}"
      echo "$result"
      ;;
  esac

  return 0
}

addMedia () {

  local mediaFile="$1"
  local mediaType="$2"
  local mediaId="$3"
  local mediaIndex="$4"
  local mediaAddress="$5"
  shift 5

  local candidate result
  local -a candidates=( "$mediaFile" "$@" )

  mediaFile=""

  for candidate in "${candidates[@]}"; do
    if [ -f "$candidate" ] && [ -s "$candidate" ]; then
      mediaFile="$candidate"
      break
    fi
  done

  [ -z "$mediaFile" ] && return 0

  local bootIndex="" address=""
  [ -n "$mediaAddress" ] && address=",addr=$mediaAddress"
  [ -n "$mediaIndex" ] && bootIndex=",bootindex=$mediaIndex"

  case "${mediaFile,,}" in

    *".img" | *".raw" )

      result=" -drive file=$mediaFile,id=$mediaId,format=raw,cache=unsafe,media=disk,if=none \
      -device usb-storage,drive=${mediaId}${bootIndex},removable=on"

      echo "$result"
      return 0
      ;;

    *".iso" )

      local bus
      bus=$(getPciBus)

      result=" -drive file=$mediaFile,id=$mediaId,format=raw,cache=unsafe,readonly=on,media=cdrom"

      case "${mediaType,,}" in

        "none" ) ;;

        "auto" )
          echo "$result" ;;

        "usb" )
          result+=",if=none \
          -device usb-storage,drive=${mediaId}${bootIndex},removable=on"
          echo "$result" ;;

        "nvme" )
          result+=",if=none \
          -device nvme,drive=${mediaId}${bootIndex},serial=${mediaId}"
          echo "$result" ;;

        "ide" | "sata" )
          result+=",if=none \
          -device ich9-ahci,id=ahci${mediaId}${address} \
          -device ide-cd,drive=${mediaId},bus=ahci${mediaId}.0${bootIndex}"
          echo "$result" ;;

        "blk" | "virtio-blk" )
          result+=",if=none \
          -device virtio-blk-pci,drive=${mediaId},bus=$bus${address}${IOTHREAD_OPT}${bootIndex}"
          echo "$result" ;;

        "scsi" | "virtio-scsi" )
          result+=",if=none \
          -device virtio-scsi-pci,id=${mediaId},bus=$bus${address}${IOTHREAD_OPT},hotplug=off \
          -device scsi-cd,drive=${mediaId},bus=${mediaId}.0${bootIndex}"
          echo "$result" ;;
      esac

      return 0 ;;

    * )
      error "Invalid media image specified, extension \".${mediaFile/*./}\" is not recognized!"
      return 80 ;;

  esac
}

finishDisks () {

  local type

  # VirtIO block and SCSI devices share one dedicated I/O thread, which
  # must be declared exactly once regardless of disk count.

  [ -z "$IOTHREAD_OPT" ] && return 0

  for type in "${DISK_TYPE,,}" "${MEDIA_TYPE,,}"; do
    case "$type" in
      "blk" | "scsi" | "virtio-blk" | "virtio-scsi" )
        [[ "$DISK_OPTS" != *" -object iothread,id=io2"* ]] && DISK_OPTS+=" -object iothread,id=io2"
        break ;;
    esac
  done

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
  local diskExt dataSize
  local available currentSize
  local previousExt
  local explicitSize="${diskSpace// /}"

  diskExt=$(fmt2ext "$diskFmt")
  local diskFile="$diskBase.$diskExt"

  dir=$(dirname "$diskFile")
  [ ! -d "$dir" ] && return 0

  space=$(normalizeSize "$diskSpace" "$diskDesc" "$dir")
  dataSize=$(numfmt --from=iec "$space")

  if ! fs=$(stat -f -c %T "$dir"); then
    error "Failed to determine filesystem type of \"$dir\" !"
    return 1
  fi

  checkFS "$fs" "$diskFile" "$diskDesc" || exit $?

  if ! supportsDirect "$fs"; then
    diskIo="threads"
    diskCache="writeback"
  fi

  if [ ! -f "$diskFile" ] || [ ! -s "$diskFile" ]; then

    # If the requested format is missing but the same managed disk exists in the
    # opposite format, convert it instead of creating a blank replacement.
    if [[ "${diskFmt,,}" != "raw" ]]; then
      local previousFmt="raw"
    else
      local previousFmt="qcow2"
    fi

    previousExt=$(fmt2ext "$previousFmt")

    if [ -f "$diskBase.$previousExt" ] &&
      [ -s "$diskBase.$previousExt" ]; then
      convertDisk "$diskBase.$previousExt" "$previousFmt" "$diskFile" "$diskFmt" "$diskBase" "$diskDesc" "$fs" || exit $?
    fi

  fi

  if [ -f "$diskFile" ] && [ -s "$diskFile" ]; then

    currentSize=$(getSize "$diskFile") || exit 71

    if (( dataSize > currentSize )); then

      if [ -n "$explicitSize" ]; then
        resizeDisk "$diskFile" "$space" "$diskDesc" "$diskFmt" "$fs" || exit $?
      fi

    else

      if (( dataSize < currentSize )); then

        if [ -n "$explicitSize" ] && [[ "${diskSpace,,}" != "max" && "${diskSpace,,}" != "half" ]]; then
          info "You decreased the ${diskDesc^^}_SIZE variable to ${diskSpace/G/ GB} but shrinking disks is not supported, will be ignored..."
        fi

      fi
    fi

  else

    createDisk "$diskFile" "$space" "$diskDesc" "$diskFmt" "$fs" || exit $?

  fi

  # Sparse images can advertise more capacity than the host can currently hold;
  # warn when future guest growth would exceed the remaining filesystem space.
  if [ -f "$diskFile" ] && disabled "$ALLOCATE"; then

    currentSize=$(getSize "$diskFile") || exit 73
    used=$(du -sB 1 "$diskFile" | cut -f1)
    available=$(df --output=avail -B 1 "$dir" | tail -n 1)
    local missing=$(( currentSize - used - available ))
    (( missing < 0 )) && missing=0

    if (( missing > 0 )); then

      local gb base

      gb=$(formatBytes "$available")
      base=$(baseDir "$dir")
      missing=$(formatBytes "$missing")
      currentSize=$(formatBytes "$currentSize")
      local msg="The virtual size of the ${diskDesc,,} is $currentSize"

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

addImage () {

  local diskFile="$1"
  local diskType="$2"
  local diskDesc="$3"
  local diskIndex="$4"
  local diskAddress="$5"

  local fs diskFmt
  local diskIo="$DISK_IO"
  local diskCache="$DISK_CACHE"

  [ -z "$diskFile" ] && return 0
  [ ! -f "$diskFile" ] && error "Image $diskFile cannot be found! Please add it to the 'volumes' section of your compose file." && exit 55
  [ ! -s "$diskFile" ] && error "Image $diskFile is empty! Please provide a valid disk image." && exit 55

  case "${diskFile,,}" in
    *".img" | *".raw" ) diskFmt="raw" ;;
    *".qcow2" ) diskFmt="qcow2" ;;
    * )
      error "Unsupported disk image extension: .${diskFile/*./}"
      error "Only .img, .raw and .qcow2 disk images are supported."
      exit 78 ;;
  esac

  if ! fs=$(stat -f -c %T "$diskFile"); then
    error "Failed to determine filesystem type of \"$diskFile\" !"
    return 1
  fi

  checkFS "$fs" "$diskFile" "$diskDesc" || exit $?

  if ! supportsDirect "$fs"; then
    diskIo="threads"
    diskCache="writeback"
  fi

  DISK_OPTS+=$(createDevice "$diskFile" "$diskType" "$diskIndex" "$diskAddress" "$diskFmt" "$diskIo" "$diskCache" "" "")

  return 0
}

addDevice () {

  local diskDev="$1"
  local diskType="$2"
  local diskIndex="$3"
  local diskAddress="$4"
  local sectors="" logical="" physical=""

  [ -z "$diskDev" ] && return 0
  [ ! -b "$diskDev" ] && error "Device $diskDev cannot be found! Please add it to the 'devices' section of your compose file." && exit 55

  local devType
  devType=$(lsblk -no TYPE "$diskDev" 2>/dev/null | head -n1)

  local result
  result=$(fdisk -l "$diskDev" 2>/dev/null | grep -m 1 -o "(logical/physical): .*" | cut -c 21- || true)

  if [ -n "$result" ]; then
    logical="${result%% *}"
    physical=$(echo "$result" | grep -m 1 -o "/ .*" | cut -c 3- || true)
    physical="${physical%% *}"
  fi

  # Report non-512 physical geometry to QEMU so guests align I/O correctly.
  # Legacy whole-disk 512e passthrough omits it for compatibility, while
  # partitions, modern boot modes and non-512 logical sectors keep the real geometry.
  if [ -z "$logical" ] || [ -z "$physical" ]; then
    warn "Failed to determine the sector size for $diskDev"
  elif [[ "$physical" != "512" ]]; then
    if [[ "$devType" != "disk" ||
          ( "${BOOT_MODE,,}" != "legacy" && "${BOOT_MODE,,}" != "windows_legacy" ) ||
          "$logical" != "512" ]]; then
      sectors=",logical_block_size=$logical,physical_block_size=$physical"
    fi
  fi

  DISK_OPTS+=$(createDevice "$diskDev" "$diskType" "$diskIndex" "$diskAddress" "raw" "$DISK_IO" "$DISK_CACHE" "" "$sectors")

  return 0
}

[ -z "${DISK_OPTS:-}" ] && DISK_OPTS=""
[ -z "${DISK_TYPE:-}" ] && DISK_TYPE="scsi"
[ -z "${DISK_NAME:-}" ] && DISK_NAME="data"
[ -z "${DISK_OFFSET:-}" ] && DISK_OFFSET="0"
[ -z "${DISK_DISABLE:-}" ] && DISK_DISABLE=""
[ -z "${DISK_MINIMUM:-}" ] && DISK_MINIMUM="100M"

if ! enabled "$DISK_DISABLE"; then
  msg="Initializing disks..."
  enabled "$DEBUG" && echo "$msg"
fi

if [ -z "$DISK_IO" ]; then
  if [[ "${BOOT_MODE,,}" == "windows_legacy" ]]; then
    DISK_IO="threads"
  else
    DISK_IO="native"
  fi
fi

IOTHREAD_OPT=",iothread=io2"
[[ "${BOOT_MODE,,}" == "windows_legacy" ]] && IOTHREAD_OPT=""

# Native AIO requires direct I/O. Buffered cache modes are automatically moved
# to the thread backend rather than constructing an invalid QEMU combination.
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

if [[ ! "$DISK_OFFSET" =~ ^[0-5]$ ]]; then
  error "Invalid DISK_OFFSET value '$DISK_OFFSET', must be between 0 and 5."
  exit 78
fi

if ! validDiskType "$DISK_TYPE"; then
  error "Invalid DISK_TYPE specified, value \"$DISK_TYPE\" is not recognized!"
  exit 80
fi

if [[ "$DISK_FLAGS" =~ [[:space:]] ]]; then
  error "Invalid DISK_FLAGS value '$DISK_FLAGS', spaces are not allowed."
  exit 78
fi

if [[ "$DISK_OPTIONS" =~ [[:space:]] ]]; then
  error "Invalid DISK_OPTIONS value '$DISK_OPTIONS', spaces are not allowed."
  exit 78
fi

# Choose a conservative removable-media controller for each platform; Windows
# legacy mode lets QEMU select the controller automatically.
if [[ "${PLATFORM,,}" != "arm64" ]]; then
  FALLBACK="ide"
else
  FALLBACK="usb"
fi

[[ "${BOOT_MODE:-}" == "windows_legacy" ]] && FALLBACK="auto"

if [ -z "${MEDIA_TYPE:-}" ]; then
  if [[ "${BOOT_MODE:-}" != "windows"* ]]; then
    if [[ "${DISK_TYPE,,}" == "blk" ]]; then
      MEDIA_TYPE="$FALLBACK"
    else
      MEDIA_TYPE="$DISK_TYPE"
    fi
  else
    MEDIA_TYPE="$FALLBACK"
  fi
fi

if ! validDiskType "$MEDIA_TYPE"; then
  error "Invalid MEDIA_TYPE specified, value \"$MEDIA_TYPE\" is not recognized!"
  exit 80
fi

if [ -s "$BOOT" ]; then
  case "${BOOT,,}" in
    *".iso" )
        # Hybrid ISOs contain an MBR signature and must be attached as USB disks;
        # Windows install media is kept on its expected optical-media path.
        if [[ "${BOOT_MODE:-}" == "windows"* ]]; then
          hybrid="0000"
        else
          hybrid=$(head -c 512 "$BOOT" | tail -c 2 | xxd -p)
        fi
        if [[ "$hybrid" != "0000" ]]; then
          DISK_OPTS+=$(addMedia "$BOOT" "usb" "boot" "$BOOT_INDEX" "0x5")
        else
          DISK_OPTS+=$(addMedia "$BOOT" "$MEDIA_TYPE" "boot" "$BOOT_INDEX" "0x5")
        fi ;;
    *".img" | *".raw" )
        DISK_OPTS+=$(createDevice "$BOOT" "$DISK_TYPE" "$BOOT_INDEX" "0x5" "raw" "$DISK_IO" "$DISK_CACHE" "" "" "boot") ;;
    *".qcow2" )
        DISK_OPTS+=$(createDevice "$BOOT" "$DISK_TYPE" "$BOOT_INDEX" "0x5" "qcow2" "$DISK_IO" "$DISK_CACHE" "" "" "boot") ;;
    * )
        error "Invalid BOOT image specified, extension \".${BOOT/*./}\" is not recognized!" && exit 80 ;;
  esac
fi

findDiskSource () {

  local sourceType="$1"
  local sourceFile="$2"
  shift 2

  local candidate

  [ -n "$sourceFile" ] && {
    echo "$sourceFile"
    return 0
  }

  for candidate in "$@"; do

    case "$sourceType" in
      "device" )
        [ -b "$candidate" ] || continue ;;

      "image" )
        [ -f "$candidate" ] || continue ;;

      * )
        error "Invalid disk source type: $sourceType"
        return 1 ;;
    esac

    echo "$candidate"
    return 0

  done

  return 0
}

# Initialize disks

DISK1_FILE="$STORAGE/${DISK_NAME}"
DISK2_FILE="/storage2/${DISK_NAME}2"
DISK3_FILE="/storage3/${DISK_NAME}3"
DISK4_FILE="/storage4/${DISK_NAME}4"
DISK5_FILE="/storage5/${DISK_NAME}5"
DISK6_FILE="/storage6/${DISK_NAME}6"

if [ -z "$DISK_FMT" ]; then
  if [ -f "$DISK1_FILE.qcow2" ]; then
    DISK_FMT="qcow2"
  else
    DISK_FMT="raw"
  fi
fi

DISK_FMT="${DISK_FMT,,}"

case "$DISK_FMT" in
  "raw" | "qcow2" ) ;;
  * ) error "Invalid DISK_FMT specified, value \"$DISK_FMT\" is not recognized!" && exit 78 ;;
esac

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

if enabled "$DISK_DISABLE"; then
  finishDisks && return 0
fi

: "${DISK2_SIZE:=""}"
: "${DISK3_SIZE:=""}"
: "${DISK4_SIZE:=""}"
: "${DISK5_SIZE:=""}"
: "${DISK6_SIZE:=""}"

: "${DEVICE:=""}"        # Docker variables to passthrough a block device, like /dev/vdc1.
: "${DEVICE2:=""}"
: "${DEVICE3:=""}"
: "${DEVICE4:=""}"
: "${DEVICE5:=""}"
: "${DEVICE6:=""}"

DISK_IMAGES=()
DISK_DEVICES=()
DISK_DEVICE_VARS=( "$DEVICE" "$DEVICE2" "$DEVICE3" "$DEVICE4" "$DEVICE5" "$DEVICE6" )

for (( i=0; i<6-DISK_OFFSET; i++ )); do

  diskNumber=$(( i + 1 ))

  if (( diskNumber == 1 )); then

    DISK_DEVICES[i]=$(findDiskSource "device" "${DISK_DEVICE_VARS[i]}" \
      "/disk" \
      "/disk1" \
      "/dev/disk1") || exit $?

    DISK_IMAGES[i]=$(findDiskSource "image" "" \
      "/${DISK_NAME}.img" \
      "/${DISK_NAME}.raw" \
      "/${DISK_NAME}.qcow2" \
      "/disk.img" \
      "/disk.raw" \
      "/disk.qcow2" \
      "/disk1.img" \
      "/disk1.raw" \
      "/disk1.qcow2") || exit $?

  else

    DISK_DEVICES[i]=$(findDiskSource "device" "${DISK_DEVICE_VARS[i]}" \
      "/disk${diskNumber}" \
      "/dev/disk${diskNumber}") || exit $?

    DISK_IMAGES[i]=$(findDiskSource "image" "" \
      "/${DISK_NAME}${diskNumber}.img" \
      "/${DISK_NAME}${diskNumber}.raw" \
      "/${DISK_NAME}${diskNumber}.qcow2" \
      "/disk${diskNumber}.img" \
      "/disk${diskNumber}.raw" \
      "/disk${diskNumber}.qcow2") || exit $?

  fi

done

unset DISK_DEVICE_VARS diskNumber

DISK_FILES=( "$DISK1_FILE" "$DISK2_FILE" "$DISK3_FILE" "$DISK4_FILE" "$DISK5_FILE" "$DISK6_FILE" )
DISK_DESCS=( "disk" "disk2" "disk3" "disk4" "disk5" "disk6" )
DISK_SIZES=( "$DISK_SIZE" "$DISK2_SIZE" "$DISK3_SIZE" "$DISK4_SIZE" "$DISK5_SIZE" "$DISK6_SIZE" )
DISK_INDEXES=( "3" "4" "5" "6" "7" "8" )
DISK_ADDRESSES=( "0xa" "0xb" "0xc" "0xd" "0xe" "0xf" )

# Source precedence is explicit block device, then bind-mounted image, then the
# managed image created under the corresponding storage directory.
for (( i=0; i<6-DISK_OFFSET; i++ )); do

  if [ -n "${DISK_DEVICES[i]}" ]; then
    addDevice "${DISK_DEVICES[i]}" "$DISK_TYPE" "${DISK_INDEXES[i]}" "${DISK_ADDRESSES[i + DISK_OFFSET]}" || exit $?
  elif [ -n "${DISK_IMAGES[i]}" ]; then
    addImage "${DISK_IMAGES[i]}" "$DISK_TYPE" "${DISK_DESCS[i]}" "${DISK_INDEXES[i]}" "${DISK_ADDRESSES[i + DISK_OFFSET]}" || exit $?
  else
    addDisk "${DISK_FILES[i]}" "$DISK_TYPE" "${DISK_DESCS[i]}" "${DISK_SIZES[i]}" "${DISK_INDEXES[i]}" "${DISK_ADDRESSES[i + DISK_OFFSET]}" "$DISK_FMT" "$DISK_IO" "$DISK_CACHE" || exit $?
  fi

done

DISK_OPTS+=$(addMedia "/start.iso" "$FALLBACK" "rescue" "1" "" "$STORAGE/start.iso")
DISK_OPTS+=$(addMedia "/mount.iso" "$FALLBACK" "drivers" "" "" "/drivers.iso" "$STORAGE/drivers.iso")
DISK_OPTS+=$(addMedia "/setup.img" "usb" "setup" "" "" "$STORAGE/setup.img" "$STORAGE/windows.setup.img")

finishDisks

return 0
