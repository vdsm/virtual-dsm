#!/usr/bin/env bash
set -Eeuo pipefail

: ${URL:=''}    # URL of the PAT file to be downloaded.

if [ -f "$STORAGE"/dsm.ver ]; then
  BASE=$(cat "$STORAGE/dsm.ver")
else
  # Fallback for old installs
  BASE="DSM_VirtualDSM_42962"
fi

[ -n "$URL" ] && BASE=$(basename "$URL" .pat)

if [[ -f "$STORAGE/$BASE.boot.img" ]] && [[ -f "$STORAGE/$BASE.system.img" ]]; then
  return 0  # Previous installation found
fi

# Display wait message
/run/server.sh 5000 install &

DL=""
DL_CHINA="https://cndl.synology.cn/download/DSM"
DL_GLOBAL="https://global.synologydownload.com/download/DSM"

[[ "${URL,,}" == *"cndl.synology"* ]] && DL="$DL_CHINA"
[[ "${URL,,}" == *"global.synology"* ]] && DL="$DL_GLOBAL"

if [ -z "$DL" ]; then
  [ -z "$COUNTRY" ] && setCountry
  [ -z "$COUNTRY" ] && info "Warning: could not detect country to select mirror!"
  [[ "${COUNTRY^^}" == "CN" ]] && DL="$DL_CHINA" || DL="$DL_GLOBAL"
fi

[ -z "$URL" ] && URL="$DL/release/7.2.1/69057-1/DSM_VirtualDSM_69057.pat"

BASE=$(basename "$URL" .pat)

if [[ "$URL" != "file://$STORAGE/$BASE.pat" ]]; then
  rm -f "$STORAGE"/"$BASE".pat
fi

rm -f "$STORAGE"/"$BASE".agent
rm -f "$STORAGE"/"$BASE".boot.img
rm -f "$STORAGE"/"$BASE".system.img

[[ "$DEBUG" == [Yy1]* ]] && set -x

# Check filesystem
MIN_ROOT=471859200
MIN_SPACE=6442450944
FS=$(stat -f -c %T "$STORAGE")

if [[ "${FS,,}" == "overlay"* ]]; then
  info "Warning: the filesystem of $STORAGE is OverlayFS, this usually means it was binded to an invalid path!"
fi

if [[ "${FS,,}" != "fat"* && "${FS,,}" != "vfat"* && "${FS,,}" != "exfat"* && \
        "${FS,,}" != "ntfs"* && "${FS,,}" != "fuse"* && "${FS,,}" != "msdos"* ]]; then
  TMP="$STORAGE/tmp"
else
  TMP="/tmp/dsm"
  SPACE=$(df --output=avail -B 1 /tmp | tail -n 1)
  if (( MIN_SPACE > SPACE )); then
    error "The ${FS^^} filesystem of $STORAGE does not support UNIX permissions, and no space left in container!" && exit 93
  fi
fi

rm -rf "$TMP" && mkdir -p "$TMP"

# Check free diskspace
SPACE=$(df --output=avail -B 1 / | tail -n 1)
(( MIN_ROOT > SPACE )) && error "Not enough free space in container root, need at least 450 MB available." && exit 96

SPACE=$(df --output=avail -B 1 "$STORAGE" | tail -n 1)
SPACE_GB=$(( (SPACE + 1073741823)/1073741824 ))
(( MIN_SPACE > SPACE )) && error "Not enough free space for installation in $STORAGE, have $SPACE_GB GB available but need at least 6 GB." && exit 94

# Check if output is to interactive TTY
if [ -t 1 ]; then
  PROGRESS="--progress=bar:noscroll"
else
  PROGRESS="--progress=dot:giga"
fi

# Download the required files from the Synology website

ROOT="Y"
RDC="$STORAGE/dsm.rd"

if [ ! -f "$RDC" ]; then

  info "Install: Downloading installer..."

  RD="$TMP/rd.gz"
  POS="65627648-71021835"
  VERIFY="b4215a4b213ff5154db0488f92c87864"
  LOC="$DL/release/7.0.1/42218/DSM_VirtualDSM_42218.pat"

  { curl -r "$POS" -sfk -S -o "$RD" "$LOC"; rc=$?; } || :
  (( rc != 0 )) && error "Failed to download $LOC, reason: $rc" && exit 60

  SUM=$(md5sum "$RD" | cut -f 1 -d " ")

  if [ "$SUM" != "$VERIFY" ]; then

    PAT="/install.pat"
    rm "$RD"
    rm -f "$PAT"

    { wget "$LOC" -O "$PAT" -q --no-check-certificate --show-progress "$PROGRESS"; rc=$?; } || :
    (( rc != 0 )) && error "Failed to download $LOC, reason: $rc" && exit 60

    tar --extract --file="$PAT" --directory="$(dirname "$RD")"/. "$(basename "$RD")"
    rm "$PAT"

  fi

  cp "$RD" "$RDC"

fi

if [ -f "$RDC" ]; then

  { xz -dc <"$RDC" >"$TMP/rd" 2>/dev/null; rc=$?; } || :
  (( rc != 1 )) && error "Failed to unxz $RDC, reason $rc" && exit 91

  { (cd "$TMP" && cpio -idm <"$TMP/rd" 2>/dev/null); rc=$?; } || :

  if (( rc != 0 )); then
    ROOT="N"
    { (cd "$TMP" && fakeroot cpio -idmu <"$TMP/rd" 2>/dev/null); rc=$?; } || :
    (( rc != 0 )) && error "Failed to extract $RDC, reason $rc" && exit 92
  fi

  mkdir -p /run/extract
  for file in $TMP/usr/lib/libcurl.so.4 \
              $TMP/usr/lib/libmbedcrypto.so.5 \
              $TMP/usr/lib/libmbedtls.so.13 \
              $TMP/usr/lib/libmbedx509.so.1 \
              $TMP/usr/lib/libmsgpackc.so.2 \
              $TMP/usr/lib/libsodium.so \
              $TMP/usr/lib/libsynocodesign-ng-virtual-junior-wins.so.7 \
              $TMP/usr/syno/bin/scemd; do
    cp "$file" /run/extract/
  done

  if [ "$ARCH" != "amd64" ]; then
    mkdir -p /lib64/
    cp "$TMP/usr/lib/libc.so.6" /lib64/
    cp "$TMP/usr/lib/libpthread.so.0" /lib64/
    cp "$TMP/usr/lib/ld-linux-x86-64.so.2" /lib64/
  fi

  mv /run/extract/scemd /run/extract/syno_extract_system_patch
  chmod +x /run/extract/syno_extract_system_patch

fi

rm -rf "$TMP" && mkdir -p "$TMP"

info "Install: Downloading $(basename "$URL")..."

PAT="/$BASE.pat"
rm -f "$PAT"

if [[ "$URL" == "file://"* ]]; then

  cp "${URL:7}" "$PAT"

else

  { wget "$URL" -O "$PAT" -q --no-check-certificate --show-progress "$PROGRESS"; rc=$?; } || :
  (( rc != 0 )) && error "Failed to download $URL, reason: $rc" && exit 69

fi

[ ! -f "$PAT" ] && error "Failed to download $URL" && exit 69

SIZE=$(stat -c%s "$PAT")

if ((SIZE<250000000)); then
  error "The specified PAT file is probably an update pack as it's too small." && exit 62
fi

info "Install: Extracting downloaded image..."

if { tar tf "$PAT"; } >/dev/null 2>&1; then

  tar xpf "$PAT" -C "$TMP/."

else

  export LD_LIBRARY_PATH="/run/extract"

  if [ "$ARCH" == "amd64" ]; then
    { /run/extract/syno_extract_system_patch "$PAT" "$TMP/."; rc=$?; } || :
  else
    { qemu-x86_64 /run/extract/syno_extract_system_patch "$PAT" "$TMP/."; rc=$?; } || :
  fi

  export LD_LIBRARY_PATH=""

  (( rc != 0 )) && error "Failed to extract PAT file, reason $rc" && exit 63

fi

info "Install: Preparing system partition..."

BOOT=$(find "$TMP" -name "*.bin.zip")
[ ! -f "$BOOT" ] && error "The PAT file contains no boot image." && exit 67

BOOT=$(echo "$BOOT" | head -c -5)
unzip -q -o "$BOOT".zip -d "$TMP"

SYSTEM="$TMP/sys.img"
SYSTEM_SIZE=4954537983
rm -f "$SYSTEM"

# Check free diskspace
SPACE=$(df --output=avail -B 1 "$TMP" | tail -n 1)
SPACE_GB=$(( (SPACE + 1073741823)/1073741824 ))
(( SYSTEM_SIZE > SPACE )) && error "Not enough free space to create a 4 GB system disk, have only $SPACE_GB GB available." && exit 97

if ! touch "$SYSTEM"; then
  error "Could not create file $SYSTEM for the system disk." && exit 98
fi
  
if [[ "${FS,,}" == "xfs" || "${FS,,}" == "zfs" || "${FS,,}" == "btrfs" || "${FS,,}" == "bcachefs" ]]; then
  { chattr +C "$SYSTEM"; } || :
  FA=$(lsattr "$SYSTEM")
  if [[ "$FA" != *"C"* ]]; then
    error "Failed to disable COW for system image $SYSTEM on ${FS^^} filesystem (returned $FA)"
  fi
fi

if ! fallocate -l "$SYSTEM_SIZE" "$SYSTEM"; then
  if ! truncate -s "$SYSTEM_SIZE" "$SYSTEM"; then
    rm -f "$SYSTEM"
    error "Could not allocate file $SYSTEM for the system disk." && exit 98
  fi
fi

# Check if file exists
[ ! -f "$SYSTEM" ] && error "System disk does not exist ($SYSTEM)" && exit 99

# Check the filesize
SIZE=$(stat -c%s "$SYSTEM")

if [[ SIZE -ne SYSTEM_SIZE ]]; then
  rm -f "$SYSTEM"
  error "System disk has the wrong size: $SIZE vs $SYSTEM_SIZE" && exit 90
fi

PART="$TMP/partition.fdisk"

{       echo "label: dos"
        echo "label-id: 0x6f9ee2e9"
        echo "device: $SYSTEM"
        echo "unit: sectors"
        echo "sector-size: 512"
        echo ""
        echo "${SYSTEM}1 : start=        2048, size=     4980480, type=83"
        echo "${SYSTEM}2 : start=     4982528, size=     4194304, type=82"
} > "$PART"

sfdisk -q "$SYSTEM" < "$PART"

MOUNT="$TMP/system"
rm -rf "$MOUNT" && mkdir -p "$MOUNT"

info "Install: Extracting system partition..."

HDA="$TMP/hda1"
IDB="$TMP/indexdb"
PKG="$TMP/packages"
HDP="$TMP/synohdpack_img"

[ ! -f "$HDA.tgz" ] && error "The PAT file contains no OS image." && exit 64

mv "$HDA.tgz" "$HDA.txz"

if [[ "$ROOT" != [Nn]* ]]; then

  tar xpfJ "$HDA.txz" --absolute-names -C "$MOUNT/"

fi

[ -d "$PKG" ] && mv "$PKG/" "$MOUNT/.SynoUpgradePackages/"
rm -f "$MOUNT/.SynoUpgradePackages/ActiveInsight-"*

[ -f "$HDP.txz" ] && tar xpfJ "$HDP.txz" --absolute-names -C "$MOUNT/"

if [ -f "$IDB.txz" ]; then
  INDEX_DB="$MOUNT/usr/syno/synoman/indexdb/"
  mkdir -p "$INDEX_DB"
  tar xpfJ "$IDB.txz" --absolute-names -C "$INDEX_DB"
fi

LABEL="1.44.1-42218"
OFFSET="1048576" # 2048 * 512
NUMBLOCKS="622560" # (4980480 * 512) / 4096

if [[ "$ROOT" != [Nn]* ]]; then

  info "Install: Installing system partition..."

  mke2fs -q -t ext4 -b 4096 -d "$MOUNT/" -L "$LABEL" -F -E "offset=$OFFSET" "$SYSTEM" "$NUMBLOCKS"

else

  fakeroot -- bash -c "set -Eeu;\
        tar xpfJ $HDA.txz --absolute-names --skip-old-files -C $MOUNT/;\
        printf '%b%s%b' '\E[1;34m❯ \E[1;36m' 'Install: Installing system partition...' '\E[0m\n';\
        mke2fs -q -t ext4 -b 4096 -d $MOUNT/ -L $LABEL -F -E offset=$OFFSET $SYSTEM $NUMBLOCKS"

fi

rm -rf "$MOUNT"

echo "$BASE" > "$STORAGE"/dsm.ver

if [[ "$URL" == "file://$STORAGE/$BASE.pat" ]]; then
  rm -f "$PAT"
else
  mv -f "$PAT" "$STORAGE"/"$BASE".pat
fi

mv -f "$BOOT" "$STORAGE"/"$BASE".boot.img
mv -f "$SYSTEM" "$STORAGE"/"$BASE".system.img

rm -rf "$TMP"

{ set +x; } 2>/dev/null
[[ "$DEBUG" == [Yy1]* ]] && echo

return 0
