#!/usr/bin/env bash
set -eu

IMG="/storage"
BASE=$(basename "$URL" .pat)

[ ! -d "$IMG" ] && echo "Storage folder (${IMG}) not found!" && exit 69
[ ! -f "/run/server.sh" ] && echo "Script must run inside Docker container!" && exit 60

[ ! -f "$IMG/$BASE.boot.img" ] && rm -f "$IMG"/"$BASE".system.img
[ -f "$IMG/$BASE.system.img" ] && exit 0

TMP="$IMG/tmp"

echo "Install: Downloading extractor..."

rm -rf $TMP && mkdir -p $TMP

FILE="$TMP/rd.gz"
curl -r 64493568-69886247 -s -k -o "$FILE" https://global.synologydownload.com/download/DSM/release/7.0.1/42218/DSM_VirtualDSM_42218.pat

set +e
xz -dc <$TMP/rd.gz >$TMP/rd 2>/dev/null
(cd $TMP && cpio -idm <$TMP/rd 2>/dev/null)
set -e

mkdir -p /run/extract
for file in $TMP/usr/lib/libcurl.so.4 $TMP/usr/lib/libmbedcrypto.so.5 $TMP/usr/lib/libmbedtls.so.13 $TMP/usr/lib/libmbedx509.so.1 $TMP/usr/lib/libmsgpackc.so.2 $TMP/usr/lib/libsodium.so $TMP/usr/lib/libsynocodesign-ng-virtual-junior-wins.so.7 $TMP/usr/syno/bin/scemd; do
  cp "$file" /run/extract/
done

mv /run/extract/scemd /run/extract/syno_extract_system_patch
chmod +x /run/extract/syno_extract_system_patch

echo "Install: Downloading $URL..."

FILE="$TMP/dsm.pat"

rm -rf $TMP && mkdir -p $TMP
wget "$URL" -O "$FILE" -q --no-check-certificate --show-progress

[ ! -f "$FILE" ] && echo "Download failed" && exit 61

SIZE=$(stat -c%s "$FILE")

if ((SIZE<250000000)); then
  echo "Invalid PAT file: File is an update pack which contains no OS image." && exit 62
fi

echo "Install: Extracting downloaded system image..."

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
PKG="$TMP/packages"
HDP="$TMP/synohdpack_img"

[ ! -f "$HDA.tgz" ] && echo "Invalid PAT file: File contains no OS image." && exit 64
[ ! -f "$HDP.txz" ] && echo "Invalid PAT file: HD pack not found." && exit 65
[ ! -f "$IDB.txz" ] && echo "Invalid PAT file: IndexDB file not found." && exit 66
[ ! -d "$PKG" ] && echo "Invalid PAT file: File contains no packages." && exit 68

BOOT=$(find $TMP -name "*.bin.zip")

[ ! -f "$BOOT" ] && echo "Invalid PAT file: boot file not found." && exit 67

BOOT=$(echo "$BOOT" | head -c -5)
unzip -q -o "$BOOT".zip -d $TMP

echo "Install: Extracting prepared disk image..."

SYSTEM="$TMP/temp.img"
PLATE="/data/template.img"

rm -f $PLATE
unxz $PLATE.xz
mv -f $PLATE $SYSTEM

echo "Install: Extracting system partition..."

PRIVILEGED=false
LABEL="1.44.1-42218"
OFFSET="1048576" # 2048 * 512
NUMBLOCKS="622560" # 2550005760 / 4096

MOUNT="/mnt/tmp"
rm -rf $MOUNT && mkdir -p $MOUNT

mount -t ext4 -o loop,offset=$OFFSET $SYSTEM $MOUNT 2>/dev/null && PRIVILEGED=true

rm -rf ${MOUNT:?}/{,.[!.],..?}*

mv -f $HDA.tgz $HDA.txz

tar xpfJ $HDP.txz --absolute-names -C $MOUNT/
tar xpfJ $HDA.txz --absolute-names -C $MOUNT/
tar xpfJ $IDB.txz --absolute-names -C $MOUNT/usr/syno/synoman/indexdb/

LOC="$MOUNT/usr/local"
mkdir -p $LOC
mv $PKG/ $LOC/

LOC="$MOUNT/usr/local/bin"
mkdir -p $LOC
mv /agent/agent.sh $LOC/agent.sh
chmod +x $LOC/agent.sh

LOC="$MOUNT/usr/local/etc/rc.d"
mkdir -p $LOC
mv /agent/service.sh $LOC/agent.sh
chmod +x $LOC/agent.sh

if [ "$PRIVILEGED" = false ]; then

  echo "Install: Installing system partition..."

  # Workaround for containers that are not privileged to mount loop devices
  mke2fs -q -t ext4 -b 4096 -d $MOUNT/ -L $LABEL -F -E offset=$OFFSET $SYSTEM $NUMBLOCKS

else

  umount $MOUNT

fi

rm -rf $MOUNT

mv -f "$BOOT" "$IMG"/"$BASE".boot.img
mv -f "$SYSTEM" "$IMG"/"$BASE".system.img

rm -rf $TMP

exit 0
