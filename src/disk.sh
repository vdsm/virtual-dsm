#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables

: ${DISK_IO:='native'}    # I/O Mode, can be set to 'native', 'threads' or 'io_turing'
: ${DISK_CACHE:='none'}   # Caching mode, can be set to 'writeback' for better performance
: ${DISK_DISCARD:='on'}   # Controls whether unmap (TRIM) commands are passed to the host.
: ${DISK_ROTATION:='1'}   # Rotation rate, set to 1 for SSD storage and increase for HDD

BOOT="$STORAGE/$BASE.boot.img"
SYSTEM="$STORAGE/$BASE.system.img"

[ ! -f "$BOOT" ] && error "Virtual DSM boot-image does not exist ($BOOT)" && exit 81
[ ! -f "$SYSTEM" ] && error "Virtual DSM system-image does not exist ($SYSTEM)" && exit 82

DATA="${STORAGE}/data.img"

if [[ ! -f "${DATA}" ]] && [[ -f "$STORAGE/data$DISK_SIZE.img" ]]; then
  # Fallback for legacy installs
  DATA="$STORAGE/data$DISK_SIZE.img"
fi

MIN_SIZE=6442450944
DISK_SIZE=$(echo "${DISK_SIZE}" | sed 's/MB/M/g;s/GB/G/g;s/TB/T/g')
DATA_SIZE=$(numfmt --from=iec "${DISK_SIZE}")

if (( DATA_SIZE < MIN_SIZE )); then
  error "Please increase DISK_SIZE to at least 6 GB." && exit 83
fi

if [ -f "${DATA}" ]; then

  OLD_SIZE=$(stat -c%s "${DATA}")

  if [ "$DATA_SIZE" -gt "$OLD_SIZE" ]; then

    info "Resizing data disk from $OLD_SIZE to $DATA_SIZE bytes.."

    if [[ "${ALLOCATE}" == [Nn]* ]]; then

      # Resize file by changing its length
      if ! truncate -s "${DATA_SIZE}" "${DATA}"; then
        error "Could not resize the file for the virtual disk." && exit 85
      fi

    else

      REQ=$((DATA_SIZE-OLD_SIZE))

      # Check free diskspace
      SPACE=$(df --output=avail -B 1 "${STORAGE}" | tail -n 1)

      if (( REQ > SPACE )); then
        error "Not enough free space to resize virtual disk to ${DISK_SIZE}."
        error "Specify a smaller size or disable preallocation with ALLOCATE=N." && exit 84
      fi

      # Resize file by allocating more space
      if ! fallocate -l "${DATA_SIZE}" "${DATA}"; then
        if ! truncate -s "${DATA_SIZE}" "${DATA}"; then
          error "Could not resize the file for the virtual disk." && exit 85
        fi
      fi

      if [[ "${ALLOCATE}" == [Zz]* ]]; then

        GB=$(( (REQ + 1073741823)/1073741824 ))

        info "Preallocating ${GB} GB of diskspace, please wait..."
        dd if=/dev/urandom of="${DATA}" seek="${OLD_SIZE}" count="${REQ}" bs=1M iflag=count_bytes oflag=seek_bytes status=none

      fi
    fi
  fi

  if [ "$DATA_SIZE" -lt "$OLD_SIZE" ]; then

    info "Shrinking existing disks is not supported yet!"
    info "Creating backup of old drive in storage folder..."

    mv -f "${DATA}" "${DATA}.bak"

  fi
fi

if [ ! -f "${DATA}" ]; then

  if [[ "${ALLOCATE}" == [Nn]* ]]; then

    # Create an empty file
    if ! truncate -s "${DATA_SIZE}" "${DATA}"; then
      rm -f "${DATA}"
      error "Could not create a file for the virtual disk." && exit 87
    fi

  else

    # Check free diskspace
    SPACE=$(df --output=avail -B 1 "${STORAGE}" | tail -n 1)

    if (( DATA_SIZE > SPACE )); then
      error "Not enough free space to create a virtual disk of ${DISK_SIZE}."
      error "Specify a smaller size or disable preallocation with ALLOCATE=N." && exit 86
    fi

    # Create an empty file
    if ! fallocate -l "${DATA_SIZE}" "${DATA}"; then
      if ! truncate -s "${DATA_SIZE}" "${DATA}"; then
        rm -f "${DATA}"
        error "Could not create a file for the virtual disk." && exit 87
      fi
    fi

    if [[ "${ALLOCATE}" == [Zz]* ]]; then

      info "Preallocating ${DISK_SIZE} of diskspace, please wait..."
      dd if=/dev/urandom of="${DATA}" count="${DATA_SIZE}" bs=1M iflag=count_bytes status=none

    fi
  fi

  # Check if file exists
  if [ ! -f "${DATA}" ]; then
    error "Virtual disk does not exist ($DATA)" && exit 88
  fi

fi

# Check the filesize
SIZE=$(stat -c%s "${DATA}")

if [[ SIZE -ne DATA_SIZE ]]; then
  error "Virtual disk has the wrong size: ${SIZE}" && exit 89
fi

DISK_OPTS="\
    -device virtio-scsi-pci,id=hw-synoboot,bus=pcie.0,addr=0xa \
    -drive file=${BOOT},if=none,id=drive-synoboot,format=raw,cache=${DISK_CACHE},aio=${DISK_IO},discard=${DISK_DISCARD},detect-zeroes=on \
    -device scsi-hd,bus=hw-synoboot.0,channel=0,scsi-id=0,lun=0,drive=drive-synoboot,id=synoboot0,rotation_rate=${DISK_ROTATION},bootindex=1 \
    -device virtio-scsi-pci,id=hw-synosys,bus=pcie.0,addr=0xb \
    -drive file=${SYSTEM},if=none,id=drive-synosys,format=raw,cache=${DISK_CACHE},aio=${DISK_IO},discard=${DISK_DISCARD},detect-zeroes=on \
    -device scsi-hd,bus=hw-synosys.0,channel=0,scsi-id=0,lun=0,drive=drive-synosys,id=synosys0,rotation_rate=${DISK_ROTATION},bootindex=2 \
    -device virtio-scsi-pci,id=hw-userdata,bus=pcie.0,addr=0xc \
    -drive file=${DATA},if=none,id=drive-userdata,format=raw,cache=${DISK_CACHE},aio=${DISK_IO},discard=${DISK_DISCARD},detect-zeroes=on \
    -device scsi-hd,bus=hw-userdata.0,channel=0,scsi-id=0,lun=0,drive=drive-userdata,id=userdata0,rotation_rate=${DISK_ROTATION},bootindex=3"

addDisk () {

  local DISK_ID=$1
  local DISK_FILE=$2
  local DISK_DESC=$3
  local DISK_SPACE=$4
  local DISK_INDEX=$5
  local DISK_ADDRESS=$6

  [ ! -d "$(dirname "${DISK_FILE}")" ] && return 0

  if [ ! -f "${DISK_FILE}" ]; then
    [ -z "$DISK_SPACE" ] && DISK_SPACE="16G"
    DATA_SIZE=$(numfmt --from=iec "${DISK_SPACE}")
    if (( DATA_SIZE < MIN_SIZE )); then
      error "Please increase ${DISK_DESC}_SIZE to at least 6 GB." && exit 54
    fi    
    if ! truncate -s "${DISK_SPACE}" "${DISK_FILE}"; then
      error "Could not create file: ${DISK_FILE}" && exit 53
    fi
  fi

  if [ -n "$DISK_SPACE" ]; then
    CUR_SIZE=$(stat -c%s "${DISK_FILE}")
    DATA_SIZE=$(numfmt --from=iec "${DISK_SPACE}")
    if (( DATA_SIZE < MIN_SIZE )); then
      error "Please increase ${DISK_DESC}_SIZE to at least 6 GB." && exit 54
    fi
    if [ "$DATA_SIZE" -gt "$CUR_SIZE" ]; then
      if ! truncate -s "${DISK_SPACE}" "${DISK_FILE}"; then
        error "Could not resize file: ${DISK_FILE}" && exit 53
      fi
    fi
  fi

  DISK_OPTS="${DISK_OPTS} \
    -device virtio-scsi-pci,id=hw-${DISK_ID},bus=pcie.0,addr=${DISK_ADDRESS} \
    -drive file=${DISK_FILE},if=none,id=drive-${DISK_ID},format=raw,cache=${DISK_CACHE},aio=${DISK_IO},discard=${DISK_DISCARD},detect-zeroes=on \
    -device scsi-hd,bus=hw-${DISK_ID}.0,channel=0,scsi-id=0,lun=0,drive=drive-${DISK_ID},id=${DISK_ID},rotation_rate=${DISK_ROTATION},bootindex=${DISK_INDEX}"

  return 0
}

addDevice () {

  local DISK_ID=$1
  local DISK_DEV=$2
  local DISK_INDEX=$3
  local DISK_ADDRESS=$4

  [ -z "${DISK_DEV}" ] && return 0
  [ ! -b "${DISK_DEV}" ] && error "Device ${DISK_DEV} cannot be found! Please add it to the 'devices' section of your compose file." && exit 55

  DISK_OPTS="${DISK_OPTS} \
    -device virtio-scsi-pci,id=hw-${DISK_ID},bus=pcie.0,addr=${DISK_ADDRESS} \
    -drive file=${DISK_DEV},if=none,id=drive-${DISK_ID},format=raw,cache=${DISK_CACHE},aio=${DISK_IO},discard=${DISK_DISCARD},detect-zeroes=on \
    -device scsi-hd,bus=hw-${DISK_ID}.0,channel=0,scsi-id=0,lun=0,drive=drive-${DISK_ID},id=${DISK_ID},rotation_rate=${DISK_ROTATION},bootindex=${DISK_INDEX}"

  return 0
}

: ${DISK2_SIZE:=''}
: ${DISK3_SIZE:=''}
: ${DISK4_SIZE:=''}
: ${DISK5_SIZE:=''}
: ${DISK6_SIZE:=''}

addDisk "userdata2" "/storage2/data.img" "DISK2" "$DISK2_SIZE" "4" "0xd"
addDisk "userdata3" "/storage3/data.img" "DISK3" "$DISK3_SIZE" "5" "0xe"
addDisk "userdata4" "/storage4/data.img" "DISK4" "$DISK4_SIZE" "9" "0x7"
addDisk "userdata5" "/storage5/data.img" "DISK5" "$DISK5_SIZE" "10" "0x8"
addDisk "userdata6" "/storage6/data.img" "DISK6" "$DISK6_SIZE" "11" "0x9"

: ${DEVICE:=''}        # Docker variable to passthrough a block device, like /dev/vdc1.
: ${DEVICE2:=''}
: ${DEVICE3:=''}

addDevice "userdata7" "$DEVICE" "6" "0xf"
addDevice "userdata8" "$DEVICE2" "7" "0x5"
addDevice "userdata9" "$DEVICE3" "8" "0x6"

return 0
