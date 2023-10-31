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

DISK_SIZE=$(echo "${DISK_SIZE}" | sed 's/MB/M/g;s/GB/G/g;s/TB/T/g')
DATA_SIZE=$(numfmt --from=iec "${DISK_SIZE}")

if (( DATA_SIZE < 6442450944 )); then
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

  # Format as BTRFS filesystem
  # mkfs.btrfs -q -L data -d single -m dup "${DATA}" > /dev/null

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

EXTRA_DISK="/storage2/data.img"

if [ -f "${EXTRA_DISK}" ]; then

  DISK_OPTS="${DISK_OPTS} \
    -device virtio-scsi-pci,id=hw-userdata2,bus=pcie.0,addr=0xd \
    -drive file=${EXTRA_DISK},if=none,id=drive-userdata2,format=raw,cache=${DISK_CACHE},aio=${DISK_IO},discard=${DISK_DISCARD},detect-zeroes=on \
    -device scsi-hd,bus=hw-userdata2.0,channel=0,scsi-id=0,lun=0,drive=drive-userdata2,id=userdata2,rotation_rate=${DISK_ROTATION},bootindex=4"

else

  [ -d "$(dirname "${EXTRA_DISK}")" ] && error "Disk image ${EXTRA_DISK} does not exist! Please supply an empty file of at least 6 GB." && exit 53

fi

EXTRA_DISK="/storage3/data.img"

if [ -f "${EXTRA_DISK}" ]; then

  DISK_OPTS="${DISK_OPTS} \
    -device virtio-scsi-pci,id=hw-userdata3,bus=pcie.0,addr=0xe \
    -drive file=${EXTRA_DISK},if=none,id=drive-userdata3,format=raw,cache=${DISK_CACHE},aio=${DISK_IO},discard=${DISK_DISCARD},detect-zeroes=on \
    -device scsi-hd,bus=hw-userdata3.0,channel=0,scsi-id=0,lun=0,drive=drive-userdata3,id=userdata3,rotation_rate=${DISK_ROTATION},bootindex=5"

else

  [ -d "$(dirname "${EXTRA_DISK}")" ] && error "Disk image ${EXTRA_DISK} does not exist! Please supply an empty file of at least 6 GB." && exit 54

fi

: ${DEVICE:=''}        # Docker variable to passthrough a block device, like /dev/vdc1.
: ${DEVICE2:=''}
: ${DEVICE3:=''}

if [ -n "${DEVICE}" ]; then

  [ ! -b "${DEVICE}" ] && error "Device ${DEVICE} cannot be found! Please add it to the 'devices' section of your compose file." && exit 55

  DISK_OPTS="${DISK_OPTS} \
    -device virtio-scsi-pci,id=hw-userdata4,bus=pcie.0,addr=0xf \
    -drive file=${DEVICE},if=none,id=drive-userdata4,format=raw,cache=${DISK_CACHE},aio=${DISK_IO},discard=${DISK_DISCARD},detect-zeroes=on \
    -device scsi-hd,bus=hw-userdata4.0,channel=0,scsi-id=0,lun=0,drive=drive-userdata4,id=userdata4,rotation_rate=${DISK_ROTATION},bootindex=6"

fi

if [ -n "${DEVICE2}" ]; then

  [ ! -b "${DEVICE2}" ] && error "Device ${DEVICE2} cannot be found! Please add it to the 'devices' section of your compose file." && exit 56

  DISK_OPTS="${DISK_OPTS} \
    -device virtio-scsi-pci,id=hw-userdata5,bus=pcie.0,addr=0x5 \
    -drive file=${DEVICE2},if=none,id=drive-userdata5,format=raw,cache=${DISK_CACHE},aio=${DISK_IO},discard=${DISK_DISCARD},detect-zeroes=on \
    -device scsi-hd,bus=hw-userdata5.0,channel=0,scsi-id=0,lun=0,drive=drive-userdata5,id=userdata5,rotation_rate=${DISK_ROTATION},bootindex=7"

fi

if [ -n "${DEVICE3}" ]; then

  [ ! -b "${DEVICE3}" ] && error "Device ${DEVICE3} cannot be found! Please add it to the 'devices' section of your compose file." && exit 57

  DISK_OPTS="${DISK_OPTS} \
    -device virtio-scsi-pci,id=hw-userdata6,bus=pcie.0,addr=0x6 \
    -drive file=${DEVICE3},if=none,id=drive-userdata6,format=raw,cache=${DISK_CACHE},aio=${DISK_IO},discard=${DISK_DISCARD},detect-zeroes=on \
    -device scsi-hd,bus=hw-userdata6.0,channel=0,scsi-id=0,lun=0,drive=drive-userdata6,id=userdata6,rotation_rate=${DISK_ROTATION},bootindex=8"

fi
