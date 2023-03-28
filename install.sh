#!/usr/bin/env bash

set -eu

if [ ! -f "/run/server.sh" ]; then
    echo "Script must run inside Docker container!"
    exit 1
fi

IMG="/storage"

[ ! -f "$IMG/boot.img" ] && rm -f $IMG/system.img

if [ ! -f "$IMG/system.img" ]; then

    echo "Downloading Synology DSM from $URL..."

    TMP="$IMG/tmp"
    FILE="$TMP/dsm.pat"

    rm -rf $TMP
    mkdir -p $TMP

    wget $URL -O $FILE -q --show-progress

    echo "Extracting DSM boot image..."

    if { tar tf "$FILE"; } >/dev/null 2>&1; then
       tar xpf $FILE -C $TMP/.
    else
       export LD_LIBRARY_PATH="/run"
       /run/syno_extract_system_patch $FILE $TMP/.
       export LD_LIBRARY_PATH=""
    fi

    rm $FILE

    BOOT=$(find $TMP -name "*.bin.zip")
    BOOT=$(echo $BOOT | head -c -5)

    unzip -q $BOOT.zip -d $TMP
    rm $BOOT.zip

    echo "Extracting DSM system image..."

    HDA="$TMP/hda1"
    mv $HDA.tgz $HDA.xz
    unxz $HDA.xz
    mv $HDA $HDA.tar

    echo "Extracting DSM disk template..."

    SYSTEM="$TMP/temp.img"
    PLATE="/data/template.img"

    rm -f $PLATE
    unxz $PLATE.xz
    mv -f $PLATE $SYSTEM

    echo "Mounting disk template..."
    MOUNT="/mnt/tmp"

    rm -rf $MOUNT
    mkdir -p $MOUNT
    guestmount -a $SYSTEM -m /dev/sda1:/ --rw $MOUNT
    rm -rf $MOUNT/{,.[!.],..?}*

    echo -n "Installing system partition.."

    tar xpf $HDA.tar --absolute-names --checkpoint=.5000 -C $MOUNT/

    echo ""
    echo "Unmounting disk template..."

    rm $HDA.tar
    guestunmount $MOUNT
    rm -rf $MOUNT

    mv -f $BOOT $IMG/boot.img
    mv -f $SYSTEM $IMG/system.img

    rm -rf $TMP
fi

FILE="$IMG/boot.img"
if [ ! -f "$FILE" ]; then
    echo "ERROR: Synology DSM boot-image does not exist ($FILE)"
    exit 2
fi

FILE="$IMG/system.img"
if [ ! -f "$FILE" ]; then
    echo "ERROR: Synology DSM system-image does not exist ($FILE)"
    exit 2
fi

FILE="$IMG/data.img"
if [ ! -f "$FILE" ]; then
    truncate -s $DISK_SIZE $FILE
    mkfs.ext4 -q $FILE
fi

if [ ! -f "$FILE" ]; then
    echo "ERROR: Synology DSM data-image does not exist ($FILE)"
    exit 2
fi

exit 0
