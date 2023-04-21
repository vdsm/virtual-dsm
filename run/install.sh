#!/usr/bin/env bash
set -eu

# Display wait message on port 5000
/run/server.sh 5000 "Please wait while Virtual DSM is installing..." > /dev/null &

DL="https://global.synologydownload.com/download/DSM"

if [ -z "$URL" ]; then

  URL="$DL/beta/7.2/64216/DSM_VirtualDSM_64216.pat"
  #URL="$DL/release/7.0.1/42218/DSM_VirtualDSM_42218.pat"
  #URL="$DL/release/7.1.1/42962-1/DSM_VirtualDSM_42962.pat"

fi

BASE=$(basename "$URL" .pat)

rm -f "$STORAGE"/"$BASE".pat
rm -f "$STORAGE"/"$BASE".agent
rm -f "$STORAGE"/"$BASE".boot.img
rm -f "$STORAGE"/"$BASE".system.img

echo "Install: Downloading extractor..."

TMP="$STORAGE/tmp"
RD="$TMP/rd.gz"
rm -rf $TMP && mkdir -p $TMP

LOC="$DL/release/7.0.1/42218/DSM_VirtualDSM_42218.pat"

if ! curl -r 64493568-69886247 -sfk -o "$RD" "$LOC"; then
  echo "Failed to download extractor, code: $?" && exit 60
fi

SUM=$(md5sum "$RD" | cut -f 1 -d " ")

if [ "$SUM" != "14fb88cb7cabddb5af1d0269bf032845" ]; then
  echo "Invalid extractor, checksum failed." && exit 61
fi

set +e
xz -dc <"$RD" >"$TMP/rd" 2>/dev/null
(cd "$TMP" && cpio -idm <"$TMP/rd" 2>/dev/null)
set -e

mkdir -p /run/extract
for file in $TMP/usr/lib/libcurl.so.4 $TMP/usr/lib/libmbedcrypto.so.5 $TMP/usr/lib/libmbedtls.so.13 $TMP/usr/lib/libmbedx509.so.1 $TMP/usr/lib/libmsgpackc.so.2 $TMP/usr/lib/libsodium.so $TMP/usr/lib/libsynocodesign-ng-virtual-junior-wins.so.7 $TMP/usr/syno/bin/scemd; do
  cp "$file" /run/extract/
done

mv /run/extract/scemd /run/extract/syno_extract_system_patch
chmod +x /run/extract/syno_extract_system_patch

rm -rf "$TMP" && mkdir -p "$TMP"

echo "Install: Downloading $(basename $URL)..."

PAT="/$BASE.pat"
rm -f "$PAT"

# Check if running with interactive TTY or redirected to docker log
if [ -t 1 ]; then
  wget "$URL" -O "$PAT" -q --no-check-certificate --show-progress --progress=bar:noscroll
else
  wget "$URL" -O "$PAT" -q --no-check-certificate --show-progress --progress=dot:giga
fi

[ ! -f "$PAT" ] && echo "Download failed" && exit 61

SIZE=$(stat -c%s "$PAT")

if ((SIZE<250000000)); then
  echo "Invalid PAT file: File is an update pack which contains no OS image." && exit 62
fi

echo "Install: Extracting downloaded image..."

if { tar tf "$PAT"; } >/dev/null 2>&1; then
   tar xpf $PAT -C $TMP/.
else
   export LD_LIBRARY_PATH="/run/extract"
   if ! /run/extract/syno_extract_system_patch $PAT $TMP/. ; then
     echo "Invalid PAT file: File is an update pack which contains no OS image." && exit 63
   fi
   export LD_LIBRARY_PATH=""
fi

HDA="$TMP/hda1"
IDB="$TMP/indexdb"
PKG="$TMP/packages"
HDP="$TMP/synohdpack_img"

[ ! -f "$HDA.tgz" ] && echo "Invalid PAT file: contains no OS image." && exit 64
[ ! -f "$HDP.txz" ] && echo "Invalid PAT file: contains no HD pack." && exit 65
[ ! -f "$IDB.txz" ] && echo "Invalid PAT file: contains no IndexDB." && exit 66
[ ! -d "$PKG" ] && echo "Invalid PAT file: contains no packages." && exit 68

BOOT=$(find $TMP -name "*.bin.zip")

[ ! -f "$BOOT" ] && echo "Invalid PAT file: contains no boot file." && exit 67

BOOT=$(echo "$BOOT" | head -c -5)
unzip -q -o "$BOOT".zip -d $TMP

[ "$ALLOCATE" != "Z" ] && echo "Install: Allocating diskspace..."

SYSTEM="$TMP/sys.img"
SYSTEM_SIZE=4954537983

# Check free diskspace
SPACE=$(df --output=avail -B 1 "$TMP" | tail -n 1)

if (( SYSTEM_SIZE > SPACE )); then
  echo "ERROR: Not enough free space to create a 4 GB system disk." && exit 87
fi

if ! fallocate -l "${SYSTEM_SIZE}" "${SYSTEM}"; then
  rm -f "${SYSTEM}"
  echo "ERROR: Could not allocate a file for the system disk." && exit 88
fi

 if [ "$ALLOCATE" = "Z" ]; then
  echo "Install: Preallocating 4 GB of diskspace..."
  dd if=/dev/urandom of="${SYSTEM}" count="${SYSTEM_SIZE}" bs=1M iflag=count_bytes status=none
fi

# Check if file exists
if [ ! -f "${SYSTEM}" ]; then
    echo "ERROR: System disk does not exist ($SYSTEM)" && exit 89
fi

# Check the filesize
SIZE=$(stat -c%s "${SYSTEM}")

if [[ SIZE -ne SYSTEM_SIZE ]]; then
  rm -f "${SYSTEM}"
  echo "ERROR: System disk has the wrong size: ${SIZE}" && exit 90
fi

echo "Install: Creating partition table..."

PART="$TMP/partition.fdisk"

{	echo "label: dos"
	echo "label-id: 0x6f9ee2e9"
	echo "device: ${SYSTEM}"
	echo "unit: sectors"
	echo "sector-size: 512"
	echo ""
	echo "${SYSTEM}1 : start=        2048, size=     4980480, type=83"
	echo "${SYSTEM}2 : start=     4982528, size=     4194304, type=82"
} > $PART

sfdisk -q $SYSTEM < $PART

echo "Install: Extracting system partition..."

MOUNT="$TMP/system"

rm -rf $MOUNT && mkdir -p $MOUNT

mv -f $HDA.tgz $HDA.txz

tar xpfJ $HDP.txz --absolute-names -C $MOUNT/
tar xpfJ $HDA.txz --absolute-names -C $MOUNT/
tar xpfJ $IDB.txz --absolute-names -C $MOUNT/usr/syno/synoman/indexdb/

# Install Agent

LOC="$MOUNT/usr/local"
mkdir -p $LOC
mv $PKG/ $LOC/

LOC="$MOUNT/usr/local/bin"
mkdir -p $LOC
cp /agent/agent.sh $LOC/agent.sh
chmod 755 $LOC/agent.sh

LOC="$MOUNT/usr/local/etc/rc.d"
mkdir -p $LOC
cp /agent/service.sh $LOC/agent.sh
chmod 755 $LOC/agent.sh

# Store agent version
echo "7" > "$STORAGE"/"$BASE".agent

echo "Install: Installing system partition..."

LABEL="1.44.1-42218"
OFFSET="1048576" # 2048 * 512
NUMBLOCKS="622560" # (4980480 * 512) / 4096

mke2fs -q -t ext4 -b 4096 -d $MOUNT/ -L $LABEL -F -E offset=$OFFSET $SYSTEM $NUMBLOCKS

rm -rf $MOUNT

echo "$BASE" > "$STORAGE"/dsm.ver
mv -f "$PAT" "$STORAGE"/"$BASE".pat
mv -f "$BOOT" "$STORAGE"/"$BASE".boot.img
mv -f "$SYSTEM" "$STORAGE"/"$BASE".system.img

rm -rf $TMP
