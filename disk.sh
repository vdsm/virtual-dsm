#!/usr/bin/env bash
set -eu

BOOT="$IMG/$BASE.boot.img"
SYSTEM="$IMG/$BASE.system.img"

[ ! -f "$BOOT" ] && echo "ERROR: Virtual DSM boot-image does not exist ($BOOT)" && exit 81
[ ! -f "$SYSTEM" ] && echo "ERROR: Virtual DSM system-image does not exist ($SYSTEM)" && exit 82

DISK_SIZE=$(echo "${DISK_SIZE}" | sed 's/MB/M/g;s/GB/G/g;s/TB/T/g')
NEW_SIZE=$(numfmt --from=iec "${DISK_SIZE}")

DATA="$IMG/data$DISK_SIZE.img"

if [ ! -f "$DATA" ]; then

    # Check free diskspace
    SPACE=$(df --output=avail -B 1 "$IMG" | tail -n 1)
    if (( NEW_SIZE > SPACE )); then
      echo "ERROR: Not enough free space to create virtual disk." && exit 87
    fi

    # Create an empty file
    if ! fallocate -l "${NEW_SIZE}" "${DATA}"; then
      rm -f "${DATA}"
      echo "ERROR: Could not allocate file for virtual disk." && exit 88
    fi
    
    # Check if file exists
    if [ ! -f "$DATA" ]; then
      echo "ERROR: Virtual DSM data-image does not exist ($DATA)" && exit 83
    fi
    
    # Format as BTRFS filesystem
    mkfs.btrfs -q -L data -d single -m dup "${DATA}" > /dev/null
fi

# Resizing requires mounting a loop device which in turn requires
# the container to be privileged, so we must disable it for now.
#
# OLD_SIZE=$(stat -c%s "${DATA}")
#
# if [ "$NEW_SIZE" -ne "$OLD_SIZE" ]; then
#   echo "Resizing data disk from $OLD_SIZE to $NEW_SIZE bytes"
#
#   if [ "$NEW_SIZE" -gt "$OLD_SIZE" ]; then
#     fallocate -l "${NEW_SIZE}" "${DATA}"
#     btrfs filesystem resize "${NEW_SIZE}" "${DATA}"
#   fi
#
#   if [ "$NEW_SIZE" -lt "$OLD_SIZE" ]; then
#     btrfs filesystem resize "${NEW_SIZE}" "${DATA}"
#     fallocate -l "${NEW_SIZE}" "${DATA}"
#   fi
# fi

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
