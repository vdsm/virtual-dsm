#!/usr/bin/env bash
set -Eeuo pipefail

: "${URL:=""}"    # URL of the PAT file to be downloaded.

if [ -f "$STORAGE/dsm.ver" ]; then
  BASE=$(<"$STORAGE/dsm.ver")
  [ -z "$BASE" ] && BASE="DSM_VirtualDSM_69057"
else
  # Fallback for old installs
  BASE="DSM_VirtualDSM_42962"
fi

if [ -n "$URL" ]; then
  BASE=$(basename "$URL" .pat)
  if [ ! -s "$STORAGE/$BASE.system.img" ]; then
    BASE=$(basename "${URL%%\?*}" .pat)
    : "${BASE//+/ }"; printf -v BASE '%b' "${_//%/\\x}"
    BASE=$(echo "$BASE" | sed -e 's/[^A-Za-z0-9._-]/_/g')
  fi
  if [[ "${URL,,}" != "http"* ]]; then
    if [ -s "$STORAGE/$BASE.pat" ]; then
      URL="file://$STORAGE/$BASE.pat"
    else
      error "File $STORAGE/$BASE.pat does not exist!" && exit 65
    fi
  fi
fi

if [[ -s "$STORAGE/$BASE.boot.img" ]] && [[ -s "$STORAGE/$BASE.system.img" ]]; then
  return 0  # Previous installation found
fi

html "Please wait while Virtual DSM is being installed..."

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

BASE=$(basename "${URL%%\?*}" .pat)
: "${BASE//+/ }"; printf -v BASE '%b' "${_//%/\\x}"
BASE=$(echo "$BASE" | sed -e 's/[^A-Za-z0-9._-]/_/g')

if [[ "$URL" != "file://$STORAGE/$BASE.pat" ]]; then
  rm -f "$STORAGE/$BASE.pat"
fi

rm -f "$STORAGE/$BASE.agent"
rm -f "$STORAGE/$BASE.boot.img"
rm -f "$STORAGE/$BASE.system.img"

# Check filesystem
FS=$(stat -f -c %T "$STORAGE")

if [[ "${FS,,}" == "overlay"* ]]; then
  info "Warning: the filesystem of $STORAGE is OverlayFS, this usually means it was binded to an invalid path!"
fi

if [[ "${FS,,}" == "fuse"* ]]; then
  info "Warning: the filesystem of $STORAGE is FUSE, this extra layer will negatively affect performance!"
fi

if [[ "${FS,,}" == "ecryptfs" ]] || [[ "${FS,,}" == "tmpfs" ]]; then
  info "Warning: the filesystem of $STORAGE is $FS, which does not support O_DIRECT mode, adjusting settings..."
fi

if [[ "${FS,,}" == "fat"* || "${FS,,}" == "vfat"* || "${FS,,}" == "msdos"* ]]; then
  error "Unable to install on $FS filesystems, please use a different filesystem for /storage." && exit 61
fi

if [[ "${FS,,}" != "exfat"* && "${FS,,}" != "ntfs"* && "${FS,,}" != "unknown"* ]]; then
  TMP="$STORAGE/tmp"
else
  TMP="/tmp/dsm"
  TMP_SPACE=2147483648
  SPACE=$(df --output=avail -B 1 /tmp | tail -n 1)
  SPACE_MB=$(( (SPACE + 1048575)/1048576 ))
  if (( TMP_SPACE > SPACE )); then
    error "Not enough free space inside the container, have $SPACE_MB MB available but need at least 2 GB." && exit 93
  fi
fi

rm -rf "$TMP" && mkdir -p "$TMP"

# Check free diskspace
ROOT_SPACE=536870912
SPACE=$(df --output=avail -B 1 / | tail -n 1)
SPACE_MB=$(( (SPACE + 1048575)/1048576 ))
(( ROOT_SPACE > SPACE )) && error "Not enough free space inside the container, have $SPACE_MB MB available but need at least 500 MB." && exit 96

MIN_SPACE=8589934592
SPACE=$(df --output=avail -B 1 "$STORAGE" | tail -n 1)
SPACE_GB=$(( (SPACE + 1073741823)/1073741824 ))
(( MIN_SPACE > SPACE )) && error "Not enough free space for installation in $STORAGE, have $SPACE_GB GB available but need at least 8 GB." && exit 94

# Check if output is to interactive TTY
if [ -t 1 ]; then
  PROGRESS="--progress=bar:noscroll"
else
  PROGRESS="--progress=dot:giga"
fi

# Download the required files from the Synology website

ROOT="Y"
RD="$TMP/rd.gz"
RDC="$STORAGE/dsm.rd"

if [ ! -s "$RDC" ] && [[ "$URL" == "file://"* ]] && [[ "${URL,,}" == *"_42218.pat" ]]; then

  rm -f "$RD"
  rm -f "$RDC"

  tar --extract --file="${URL:7}" --directory="$(dirname "$RD")"/. "$(basename "$RD")"
  cp "$RD" "$RDC"

fi

if [ ! -s "$RDC" ]; then

  rm -f "$RD"
  rm -f "$RDC"

  MSG="Downloading installer"
  info "Install: $MSG..." && html "$MSG..."

  SIZE=5394188
  POS="65627648-71021835"
  VERIFY="b4215a4b213ff5154db0488f92c87864"
  LOC="$DL/release/7.0.1/42218/DSM_VirtualDSM_42218.pat"
  [[ "${URL,,}" == *"_42218.pat" ]] && LOC="$URL"

  /run/progress.sh "$RD" "$SIZE" "$MSG ([P])..." &
  { curl -r "$POS" -sfk --connect-timeout 10 -S -o "$RD" "$LOC"; rc=$?; } || :

  fKill "progress.sh"

  ERR="Failed to download $LOC"
  (( rc == 3 )) && error "$ERR , cannot write file (disk full?)" && exit 60
  (( rc == 4 )) && error "$ERR , network failure!" && exit 60
  (( rc == 8 )) && error "$ERR , server issued an error response!" && exit 60

  if (( rc != 0 )); then
    if (( rc != 22 )) && (( rc != 56 )); then
      error "$ERR , reason: $rc" && exit 60
    fi
    SUM="skip"
  else
    SUM=$(md5sum "$RD" | cut -f 1 -d " ")
  fi

  if [ "$SUM" != "$VERIFY" ]; then

    PAT="/install.pat"
    SIZE=379637760

    rm -f "$RD"
    rm -f "$PAT"

    html "$MSG..."
    /run/progress.sh "$PAT" "$SIZE" "$MSG ([P])..." &
    { wget "$LOC" -O "$PAT" -q --no-check-certificate --timeout=10 --show-progress "$PROGRESS"; rc=$?; } || :

    fKill "progress.sh"

    ERR="Failed to download $LOC"
    (( rc == 3 )) && error "$ERR , cannot write file (disk full?)" && exit 60
    (( rc == 4 )) && error "$ERR , network failure!" && exit 60
    (( rc == 8 )) && error "$ERR , server issued an error response!" && exit 60
    (( rc != 0 )) && error "$ERR , reason: $rc" && exit 60

    tar --extract --file="$PAT" --directory="$(dirname "$RD")"/. "$(basename "$RD")"
    rm "$PAT"

  fi

  cp "$RD" "$RDC"

fi

if [ -f "$RDC" ]; then

  { xz -dc <"$RDC" >"$TMP/rd" 2>/dev/null; rc=$?; } || :
  (( rc != 1 )) && error "Failed to unxz $RDC on $FS, reason $rc" && exit 91

  { (cd "$TMP" && cpio -idm <"$TMP/rd" 2>/dev/null); rc=$?; } || :

  if (( rc != 0 )); then
    ROOT="N"
    { (cd "$TMP" && fakeroot cpio -idmu <"$TMP/rd" 2>/dev/null); rc=$?; } || :
    (( rc != 0 )) && error "Failed to extract $RDC on $FS, reason $rc" && exit 92
  fi

  rm -rf /run/extract && mkdir -p /run/extract
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

info "Install: Downloading $BASE.pat..."

MSG="Downloading DSM"
ERR="Failed to download $URL"

html "$MSG..."

PAT="/$BASE.pat"
rm -f "$PAT"

if [[ "$URL" == "file://"* ]]; then

  cp "${URL:7}" "$PAT"

else

  SIZE=0
  [[ "${URL,,}" == *"_69057.pat" ]] && SIZE=363837333
  [[ "${URL,,}" == *"_42218.pat" ]] && SIZE=379637760

  /run/progress.sh "$PAT" "$SIZE" "$MSG ([P])..." &

  { wget "$URL" -O "$PAT" -q --no-check-certificate --timeout=10 --show-progress "$PROGRESS"; rc=$?; } || :

  fKill "progress.sh"

  (( rc == 3 )) && error "$ERR , cannot write file (disk full?)" && exit 69
  (( rc == 4 )) && error "$ERR , network failure!" && exit 69
  (( rc == 8 )) && error "$ERR , server issued an error response!" && exit 69
  (( rc != 0 )) && error "$ERR , reason: $rc" && exit 69

fi

[ ! -s "$PAT" ] && error "$ERR" && exit 69

SIZE=$(stat -c%s "$PAT")

if ((SIZE<250000000)); then
  error "The specified PAT file is probably an update pack as it's too small." && exit 62
fi

MSG="Extracting downloaded image..."
info "Install: $MSG" && html "$MSG"

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

rm -rf /run/extract

MSG="Preparing system partition..."
info "Install: $MSG" && html "$MSG"

BOOT=$(find "$TMP" -name "*.bin.zip")
[ ! -s "$BOOT" ] && error "The PAT file contains no boot image." && exit 67

BOOT=$(echo "$BOOT" | head -c -5)
unzip -q -o "$BOOT".zip -d "$TMP"

SYSTEM="$STORAGE/$BASE.system.img"
rm -f "$SYSTEM"

# Check free diskspace
SYSTEM_SIZE=4954537983
SPACE=$(df --output=avail -B 1 "$STORAGE" | tail -n 1)
SPACE_MB=$(( (SPACE + 1048575)/1048576 ))

if (( SYSTEM_SIZE > SPACE )); then
  error "Not enough free space in $STORAGE to create a 5 GB system disk, have only $SPACE_MB MB available." && exit 97
fi

if ! touch "$SYSTEM"; then
  error "Could not create file $SYSTEM for the system disk." && exit 98
fi

if [[ "${FS,,}" == "btrfs" ]]; then
  { chattr +C "$SYSTEM"; } || :
  FA=$(lsattr "$SYSTEM")
  if [[ "$FA" != *"C"* ]]; then
    error "Failed to disable COW for system image $SYSTEM on ${FS^^} filesystem."
  fi
fi

if ! fallocate -l "$SYSTEM_SIZE" "$SYSTEM"; then
  if ! truncate -s "$SYSTEM_SIZE" "$SYSTEM"; then
    rm -f "$SYSTEM"
    error "Could not allocate file $SYSTEM for the system disk." && exit 98
  fi
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

MSG="Extracting system partition..."
info "Install: $MSG" && html "$MSG"

HDA="$TMP/hda1"
IDB="$TMP/indexdb"
PKG="$TMP/packages"
HDP="$TMP/synohdpack_img"

[ ! -s "$HDA.tgz" ] && error "The PAT file contains no OS image." && exit 64
mv "$HDA.tgz" "$HDA.txz"

[ -d "$PKG" ] && mv "$PKG/" "$MOUNT/.SynoUpgradePackages/"
rm -f "$MOUNT/.SynoUpgradePackages/ActiveInsight-"*

[ -s "$HDP.txz" ] && tar xpfJ "$HDP.txz" --absolute-names -C "$MOUNT/"

if [ -s "$IDB.txz" ]; then
  INDEX_DB="$MOUNT/usr/syno/synoman/indexdb/"
  mkdir -p "$INDEX_DB"
  tar xpfJ "$IDB.txz" --absolute-names -C "$INDEX_DB"
fi

LABEL="1.44.1-42218"
OFFSET="1048576" # 2048 * 512
NUMBLOCKS="622560" # (4980480 * 512) / 4096
MSG="Installing system partition..."

if [[ "$ROOT" != [Nn]* ]]; then

  tar xpfJ "$HDA.txz" --absolute-names --skip-old-files -C "$MOUNT/"

  info "Install: $MSG" && html "$MSG"

  mke2fs -q -t ext4 -b 4096 -d "$MOUNT/" -L "$LABEL" -F -E "offset=$OFFSET" "$SYSTEM" "$NUMBLOCKS"

else

  fakeroot -- bash -c "set -Eeu;\
        tar xpfJ $HDA.txz --absolute-names --skip-old-files -C $MOUNT/;\
        printf '%b%s%b' '\E[1;34m❯ \E[1;36m' 'Install: $MSG' '\E[0m\n';\
        mke2fs -q -t ext4 -b 4096 -d $MOUNT/ -L $LABEL -F -E offset=$OFFSET $SYSTEM $NUMBLOCKS"

fi

rm -rf "$MOUNT"
echo "$BASE" > "$STORAGE/dsm.ver"

if [[ "$URL" == "file://$STORAGE/$BASE.pat" ]]; then
  rm -f "$PAT"
else
  mv -f "$PAT" "$STORAGE/$BASE.pat"
fi

mv -f "$BOOT" "$STORAGE/$BASE.boot.img"
rm -rf "$TMP"

html "Installation finished successfully..."
return 0
