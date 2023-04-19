#!/usr/bin/env bash
set -eu

BOOT="$STORAGE/$BASE.boot.img"
SYSTEM="$STORAGE/$BASE.system.img"

[ ! -f "$BOOT" ] && echo "ERROR: Virtual DSM boot-image does not exist ($BOOT)" && exit 81
[ ! -f "$SYSTEM" ] && echo "ERROR: Virtual DSM system-image does not exist ($SYSTEM)" && exit 82

DATA="${STORAGE}/data.img"

if [[ ! -f "${DATA}" ]] && [[ -f "$STORAGE/data$DISK_SIZE.img" ]]; then
  # Fallback for legacy installs
  DATA="$STORAGE/data$DISK_SIZE.img"
fi

DISK_SIZE=$(echo "${DISK_SIZE}" | sed 's/MB/M/g;s/GB/G/g;s/TB/T/g')
DATA_SIZE=$(numfmt --from=iec "${DISK_SIZE}")

if (( DATA_SIZE < 6442450944 )); then
  echo "ERROR: Please increase DISK_SIZE to at least 6 GB." && exit 83
fi

if [ -f "${DATA}" ]; then

  OLD_SIZE=$(stat -c%s "${DATA}")

  if [ "$DATA_SIZE" -gt "$OLD_SIZE" ]; then

    echo "INFO: Resizing data disk from $OLD_SIZE to $DATA_SIZE bytes.."

    if [ "$ALLOCATE" != "Y" ]; then

      truncate -s "${DATA_SIZE}" "${DATA}"; 

    else

      REQ=$((DATA_SIZE-OLD_SIZE))

      # Check free diskspace    
      SPACE=$(df --output=avail -B 1 "${STORAGE}" | tail -n 1)

      if (( REQ > SPACE )); then
        echo "ERROR: Not enough free space to resize virtual disk to ${DISK_SIZE}."
        echo "ERROR: Specify a smaller size or disable preallocation with ALLOCATION=N." && exit 84
      fi

      if [ "$ALLOCATE" = "F" ]; then

        GB=$(( (REQ + 1073741823)/1073741824 ))
        echo "INFO: Writing ${GB} GB of zeroes, please wait.."

        dd if=/dev/zero of="${DATA}" seek="{OLD_SIZE}" count="${REQ}" bs=1M iflag=count_bytes oflag=seek_bytes

      else

        if ! fallocate -l "${DATA_SIZE}" "${DATA}"; then
          echo "ERROR: Could not allocate a file for the virtual disk." && exit 85
        fi

      fi
    fi
  fi

  if [ "$DATA_SIZE" -lt "$OLD_SIZE" ]; then

    echo "INFO: Shrinking existing disks is not supported yet!"
    echo "INFO: Creating backup of old drive in storage folder..."

    mv -f "${DATA}" "${DATA}.bak"

  fi
fi

if [ ! -f "${DATA}" ]; then

  # Create an empty file

  if [ "$ALLOCATE" = "N" ]; then

    truncate -s "${DATA_SIZE}" "${DATA}"

  else

    # Check free diskspace
    SPACE=$(df --output=avail -B 1 "${STORAGE}" | tail -n 1)

    if (( DATA_SIZE > SPACE )); then
      echo "ERROR: Not enough free space to create a virtual disk of ${DISK_SIZE}."
      echo "ERROR: Specify a smaller size or disable preallocation with ALLOCATION=N." && exit 86
    fi

    if [ "$ALLOCATE" = "F" ]; then

      echo "INFO: Writing ${DISK_SIZE} of zeroes, please wait.."

      dd if=/dev/zero of="${DATA}" count="${DATA_SIZE}" bs=1M iflag=count_bytes

    else

      if ! fallocate -l "${DATA_SIZE}" "${DATA}"; then
        rm -f "${DATA}"
        echo "ERROR: Could not allocate a file for the virtual disk." && exit 87
      fi

    fi
  fi

  # Check if file exists
  if [ ! -f "${DATA}" ]; then
    echo "ERROR: Virtual disk does not exist ($DATA)" && exit 88
  fi

  # Format as BTRFS filesystem
  mkfs.btrfs -q -L data -d single -m dup "${DATA}" > /dev/null

fi

# Check the filesize
SIZE=$(stat -c%s "${DATA}")

if [[ SIZE -ne DATA_SIZE ]]; then
  echo "ERROR: Virtual disk has the wrong size: ${SIZE}" && exit 89
fi

AGENT="${STORAGE}/${BASE}.agent"
[ -f "$AGENT" ] && AGENT_VERSION=$(cat "${AGENT}") || AGENT_VERSION=1

if ((AGENT_VERSION < 5)); then
  echo "INFO: The installed VirtualDSM Agent v${AGENT_VERSION} is an outdated version, please upgrade it."
fi

KVM_DISK_OPTS="\
    -device virtio-scsi-pci,id=hw-synoboot,bus=pcie.0,addr=0xa \
    -drive file=${BOOT},if=none,id=drive-synoboot,format=raw,cache=none,aio=native,discard=on,detect-zeroes=on \
    -device scsi-hd,bus=hw-synoboot.0,channel=0,scsi-id=0,lun=0,drive=drive-synoboot,id=synoboot0,rotation_rate=1,bootindex=1 \
    -device virtio-scsi-pci,id=hw-synosys,bus=pcie.0,addr=0xb \
    -drive file=${SYSTEM},if=none,id=drive-synosys,format=raw,cache=none,aio=native,discard=on,detect-zeroes=on \
    -device scsi-hd,bus=hw-synosys.0,channel=0,scsi-id=0,lun=0,drive=drive-synosys,id=synosys0,rotation_rate=1,bootindex=2 \
    -device virtio-scsi-pci,id=hw-userdata,bus=pcie.0,addr=0xc \
    -drive file=${DATA},if=none,id=drive-userdata,format=raw,cache=none,aio=native,discard=on,detect-zeroes=on \
    -device scsi-hd,bus=hw-userdata.0,channel=0,scsi-id=0,lun=0,drive=drive-userdata,id=userdata0,rotation_rate=1,bootindex=3"
