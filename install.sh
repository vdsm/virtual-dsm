#!/usr/bin/env bash

set -eu
IMG="/storage"

[ ! -f "/run/server.sh" ] && echo "Script must run inside Docker container!" && exit 60
[ ! -f "$IMG/boot.img" ] && rm -f $IMG/system.img

if [ ! -f "$IMG/system.img" ]; then

    echo "Downloading $URL..."

    TMP="$IMG/tmp"
    FILE="$TMP/dsm.pat"

    rm -rf $TMP && mkdir -p $TMP
    wget $URL -O $FILE -q --show-progress

    [ ! -f "$FILE" ] && echo "Download failed" && exit 61

    SIZE=$(stat -c%s "$FILE")

    if ((SIZE<250000000)); then
      echo "Invalid PAT file: File is an update pack which contains no OS image." && exit 62
    fi

    echo "Extracting boot image..."

    if { tar tf "$FILE"; } >/dev/null 2>&1; then
       tar xpf $FILE -C $TMP/.
    else
       export LD_LIBRARY_PATH="/run"
       if ! /run/syno_extract_system_patch $FILE $TMP/. ; then
         echo "Invalid PAT file: File is an update pack which contains no OS image." && exit 63
       fi
       export LD_LIBRARY_PATH=""
    fi

    rm $FILE

    HDA="$TMP/hda1"
    HDP="$TMP/synohdpack_img"
    IDB="$TMP/indexdb"

    [ ! -f "$HDA.tgz" ] && echo "Invalid PAT file: File contains no OS image." && exit 64
    [ ! -f "$HDP.txz" ] && echo "Invalid PAT file: HD pack not found." && exit 65
    [ ! -f "$IDB.txz" ] && echo "Invalid PAT file: IndexDB file not found." && exit 66

    BOOT=$(find $TMP -name "*.bin.zip")

    [ ! -f "$BOOT" ] && echo "Invalid PAT file: boot file not found." && exit 67

    BOOT=$(echo $BOOT | head -c -5)

    unzip -q $BOOT.zip -d $TMP
    rm $BOOT.zip

    echo "Extracting system image..."

    mv $HDA.tgz $HDA.xz
    unxz $HDA.xz
    mv $HDA $HDA.tar

    echo "Extracting disk image..."

    SYSTEM="$TMP/temp.img"
    PLATE="/data/template.img"

    rm -f $PLATE
    unxz $PLATE.xz
    mv -f $PLATE $SYSTEM

    echo "Mounting disk image..."
    MOUNT="/mnt/tmp"

    rm -rf $MOUNT
    mkdir -p $MOUNT
    guestmount -a $SYSTEM -m /dev/sda1:/ --rw $MOUNT
    rm -rf $MOUNT/{,.[!.],..?}*

    echo -n "Installing system partition.."

    tar xpf $HDP.txz --absolute-names -C $MOUNT/
    tar xpf $HDA.tar --absolute-names --checkpoint=.6000 -C $MOUNT/
    tar xpf $IDB.txz --absolute-names -C $MOUNT/usr/syno/synoman/indexdb/

    echo ""
    echo "Unmounting disk template..."

    rm $HDA.tar
    rm $HDP.txz
    rm $IDB.txz

    guestunmount $MOUNT
    rm -rf $MOUNT

    mv -f $BOOT $IMG/boot.img
    mv -f $SYSTEM $IMG/system.img

    rm -rf $TMP
fi

exit 0
