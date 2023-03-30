#!/usr/bin/env bash
set -eu

IMG="/storage"

[ ! -f "/run/server.sh" ] && echo "Script must run inside Docker container!" && exit 60

[ ! -f "$IMG/boot.img" ] && rm -f $IMG/system.img
[ -f "$IMG/system.img" ] && exit 0

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

    echo "Extracting downloaded system image..."

    if { tar tf "$FILE"; } >/dev/null 2>&1; then
       tar xpf $FILE -C $TMP/.
    else
       export LD_LIBRARY_PATH="/run/extract"
       if ! /run/extract/syno_extract_system_patch $FILE $TMP/. ; then
         echo "Invalid PAT file: File is an update pack which contains no OS image." && exit 63
       fi
       export LD_LIBRARY_PATH=""
    fi

    HDA="$TMP/hda1"
    IDB="$TMP/indexdb"
    HDP="$TMP/synohdpack_img"

    [ ! -f "$HDA.tgz" ] && echo "Invalid PAT file: File contains no OS image." && exit 64
    [ ! -f "$HDP.txz" ] && echo "Invalid PAT file: HD pack not found." && exit 65
    [ ! -f "$IDB.txz" ] && echo "Invalid PAT file: IndexDB file not found." && exit 66

    echo "Extracting downloaded boot image..."

    BOOT=$(find $TMP -name "*.bin.zip")

    [ ! -f "$BOOT" ] && echo "Invalid PAT file: boot file not found." && exit 67

    BOOT=$(echo $BOOT | head -c -5)
    unzip -q -o $BOOT.zip -d $TMP

    echo "Extracting prepared disk image..."

    SYSTEM="$TMP/temp.img"
    PLATE="/data/template.img"

    rm -f $PLATE
    unxz $PLATE.xz
    mv -f $PLATE $SYSTEM

    echo "Installing system partition..."

    MOUNT="/mnt/tmp"
    rm -rf $MOUNT && mkdir -p $MOUNT

    OFFSET=$(parted -s $SYSTEM unit B print | sed 's/^ //g' | grep "^1 " | tr -s ' ' | cut -d ' ' -f2 | sed 's/[^0-9]*//g')

    if [ "$OFFSET" != "1048576" ]; then
      echo "Invalid disk image, wrong offset: $OFFSET" && exit 68
    fi

    if ! mount -t ext4 -o loop,offset=$OFFSET $SYSTEM $MOUNT ; then
      echo "Failed to mount disk image. Docker container needs to be in privileged mode during installation." && exit 69
    fi

    rm -rf $MOUNT/{,.[!.],..?}*

    mv $HDA.tgz $HDA.txz

    tar xpfJ $HDP.txz --absolute-names -C $MOUNT/
    tar xpfJ $HDA.txz --absolute-names -C $MOUNT/
    tar xpfJ $IDB.txz --absolute-names -C $MOUNT/usr/syno/synoman/indexdb/

    umount $MOUNT
    rm -rf $MOUNT

    mv -f $BOOT $IMG/boot.img
    mv -f $SYSTEM $IMG/system.img

    rm -rf $TMP

exit 0
