#!/usr/bin/env bash
set -eu

IMG="/storage"
BASE=$(basename "$URL" .pat)

FILE="$IMG/$BASE.boot.img"
[ ! -f "$FILE" ] && echo "ERROR: Virtual DSM boot-image does not exist ($FILE)" && exit 81

FILE="$IMG/$BASE.system.img"
[ ! -f "$FILE" ] && echo "ERROR: Virtual DSM system-image does not exist ($FILE)" && exit 82

DISK_SIZE=$(echo "${DISK_SIZE}" | sed 's/MB/M/g;s/GB/G/g;s/TB/T/g')
NEW_SIZE=$(numfmt --from=iec "${DISK_SIZE}")

FILE="$IMG/data$DISK_SIZE.img"

if [ ! -f "$FILE" ]; then
    truncate -s "${NEW_SIZE}" "${FILE}"
    mkfs.btrfs -q -L data -d single -m dup "${FILE}" > /dev/null
    #qemu-img convert -f raw -O qcow2 -o extended_l2=on,cluster_size=128k,compression_type=zstd,preallocation=metadata "$TMP" "$FILE"
fi

[ ! -f "$FILE" ] && echo "ERROR: Virtual DSM data-image does not exist ($FILE)" && exit 83

#OLD_SIZE=$(stat -c%s "${FILE}")
#
#if [ "$NEW_SIZE" -ne "$OLD_SIZE" ]; then
#  echo "Resizing data disk from $OLD_SIZE to $NEW_SIZE bytes"
#
#  if [ "$NEW_SIZE" -gt "$OLD_SIZE" ]; then
#    truncate -s "${NEW_SIZE}" "${FILE}"
#    btrfs filesystem resize "${NEW_SIZE}" "${FILE}"
#  fi
#
#  if [ "$NEW_SIZE" -lt "$OLD_SIZE" ]; then
#    btrfs filesystem resize "${NEW_SIZE}" "${FILE}"
#    truncate -s "${NEW_SIZE}" "${FILE}"
#  fi
#fi

KVM_DISK_OPTS="\
    -device virtio-scsi-pci,id=hw-synoboot,bus=pcie.0,addr=0xa \
    -drive file=${IMG}/${BASE}.boot.img,if=none,id=drive-synoboot,format=raw,cache=none,aio=native,discard=on,detect-zeroes=on \
    -device scsi-hd,bus=hw-synoboot.0,channel=0,scsi-id=0,lun=0,drive=drive-synoboot,id=synoboot0,rotation_rate=1,bootindex=1 \
    -device virtio-scsi-pci,id=hw-synosys,bus=pcie.0,addr=0xb \
    -drive file=${IMG}/${BASE}.system.img,if=none,id=drive-synosys,format=raw,cache=none,aio=native,discard=on,detect-zeroes=on \
    -device scsi-hd,bus=hw-synosys.0,channel=0,scsi-id=0,lun=0,drive=drive-synosys,id=synosys0,rotation_rate=1,bootindex=2 \
    -device virtio-scsi-pci,id=hw-userdata,bus=pcie.0,addr=0xc \
    -drive file=${IMG}/data${DISK_SIZE}.img,if=none,id=drive-userdata,format=raw,cache=none,aio=native,discard=on,detect-zeroes=on \
    -device scsi-hd,bus=hw-userdata.0,channel=0,scsi-id=0,lun=0,drive=drive-userdata,id=userdata0,rotation_rate=1,bootindex=3"
