#!/usr/bin/env bash
set -Eeuo pipefail

: "${URL:=""}"    # URL of the PAT file to be downloaded.

if [ -f "$STORAGE/dsm.ver" ]; then
  BASE=$(<"$STORAGE/dsm.ver")
  BASE="${BASE//[![:print:]]/}"
  [ -z "$BASE" ] && BASE="DSM_VirtualDSM_69057"
else
  # Fallback for old installs
  BASE="DSM_VirtualDSM_42962"
fi

FN="boot.pat"
DIR=$(find / -maxdepth 1 -type d -iname "$FN" -print -quit)
[ ! -d "$DIR" ] && DIR=$(find "$STORAGE" -maxdepth 1 -type d -iname "$FN" -print -quit)

if [ -d "$DIR" ]; then
  BASE="DSM_VirtualDSM" && URL="file://$DIR" 
  if [[ ! -s "$STORAGE/$BASE.boot.img" || ! -s "$STORAGE/$BASE.system.img" ]]; then
    error "The bind $DIR maps to a file that does not exist!" && exit 65
  fi
fi

FILE=$(find / -maxdepth 1 -type f -iname "$FN" -print -quit)
[ ! -s "$FILE" ] && FILE=$(find "$STORAGE" -maxdepth 1 -type f -iname "$FN" -print -quit)
[ -s "$FILE" ] && BASE="DSM_VirtualDSM" && URL="file://$FILE" 

if [ -n "$URL" ] && [ ! -s "$FILE" ] && [ ! -d "$DIR" ]; then
  BASE=$(basename "$URL" .pat)
  if [ ! -s "$STORAGE/$BASE.system.img" ]; then
    BASE=$(basename "${URL%%\?*}" .pat)
    : "${BASE//+/ }"; printf -v BASE '%b' "${_//%/\\x}"
    BASE=$(echo "$BASE" | sed -e 's/[^A-Za-z0-9._-]/_/g')
  fi
  if [[ "${URL,,}" != "http"* && "${URL,,}" != "file:"* ]] ; then
    [ ! -s "$STORAGE/$BASE.pat" ] && error "Invalid URL:  $URL" && exit 65
    URL="file://$STORAGE/$BASE.pat"
  fi
fi

if [[ -s "$STORAGE/$BASE.boot.img" && -s "$STORAGE/$BASE.system.img" ]]; then
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

if [ -z "$URL" ]; then
  URL="$DL/release/7.2.2/72806/DSM_VirtualDSM_72806.pat"
fi

if [ ! -s "$FILE" ]; then
  BASE=$(basename "${URL%%\?*}" .pat)
  : "${BASE//+/ }"; printf -v BASE '%b' "${_//%/\\x}"
  BASE=$(echo "$BASE" | sed -e 's/[^A-Za-z0-9._-]/_/g')
fi

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

if [[ "${FS,,}" == "ecryptfs" || "${FS,,}" == "tmpfs" ]]; then
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
  SPACE_MB=$(formatBytes "$SPACE")
  if (( TMP_SPACE > SPACE )); then
    error "Not enough free space inside the container, have $SPACE_MB available but need at least 2 GB." && exit 93
  fi
fi

rm -rf "$TMP" && mkdir -p "$TMP"

# Check free diskspace
ROOT_SPACE=536870912
SPACE=$(df --output=avail -B 1 / | tail -n 1)
SPACE_MB=$(formatBytes "$SPACE" "down")
(( ROOT_SPACE > SPACE )) && error "Not enough free space inside the container, have $SPACE_MB available but need at least 500 MB." && exit 96

MIN_SPACE=15032385536
SPACE=$(df --output=avail -B 1 "$STORAGE" | tail -n 1)
SPACE_GB=$(formatBytes "$SPACE")
(( MIN_SPACE > SPACE )) && error "Not enough free space for installation in $STORAGE, have $SPACE_GB available but need at least 14 GB." && exit 94

# Check if output is to interactive TTY
if [ -t 1 ]; then
  PROGRESS="--progress=bar:noscroll"
else
  PROGRESS="--progress=dot:giga"
fi

if [[ "$URL" == "file://"* ]]; then
  MSG="Copying DSM"
  ERR="Failed to copy ${URL:7}"
  info "Install: Copying installation image..."
else
  MSG="Downloading DSM"
  ERR="Failed to download $URL"
  info "Install: Downloading $BASE.pat..."
fi

html "$MSG..."

PAT="/$BASE.pat"
rm -f "$PAT"

if [[ "$URL" == "file://"* ]]; then

  if [ ! -f "${URL:7}" ]; then
    error "File '${URL:7}' does not exist!" && exit 65
  fi

  cp "${URL:7}" "$PAT"

else

  SIZE=0
  [[ "${URL,,}" == *"_72806.pat" ]] && SIZE=361010261
  [[ "${URL,,}" == *"_69057.pat" ]] && SIZE=363837333
  [[ "${URL,,}" == *"_42218.pat" ]] && SIZE=379637760

  /run/progress.sh "$PAT" "$SIZE" "$MSG ([P])..." &

  { wget "$URL" -O "$PAT" -q --no-check-certificate --timeout=10 --no-http-keep-alive --show-progress "$PROGRESS"; rc=$?; } || :

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

MSG="Extracting installation image..."
info "Install: $MSG" && html "$MSG"

if { tar tf "$PAT"; } >/dev/null 2>&1; then

  tar xpf "$PAT" -C "$TMP/."

else

  { (cd "$TMP" && python3 /run/extract.py -i "$PAT" -d 2>/run/extract.log); rc=$?; } || :

  if (( rc != 0 )); then
    cat /run/extract.log
    error "Failed to extract PAT file, reason $rc" && exit 63
  fi

fi

MSG="Preparing system partition..."
info "Install: $MSG" && html "$MSG"

BOOT=$(find "$TMP" -name "*.bin.zip")
[ ! -s "$BOOT" ] && error "The PAT file contains no boot image." && exit 67

BOOT=$(echo "$BOOT" | head -c -5)
unzip -q -o "$BOOT".zip -d "$TMP"

SYSTEM="$STORAGE/$BASE.system.img"
rm -f "$SYSTEM"

# Check free diskspace
SYSTEM_SIZE=10738466816
SPACE=$(df --output=avail -B 1 "$STORAGE" | tail -n 1)
SPACE_MB=$(formatBytes "$SPACE")

if (( SYSTEM_SIZE > SPACE )); then
  error "Not enough free space in $STORAGE to create a 10 GB system disk, have only $SPACE_MB available." && exit 97
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

if ! fallocate -l "$SYSTEM_SIZE" "$SYSTEM" &>/dev/null; then
  if ! fallocate -l -x "$SYSTEM_SIZE" "$SYSTEM"; then
    if ! truncate -s "$SYSTEM_SIZE" "$SYSTEM"; then
      rm -f "$SYSTEM"
      error "Could not allocate file $SYSTEM for the system disk." && exit 98
    fi
  fi
fi

PART="$TMP/partition.fdisk"

{       echo "label: dos"
        echo "label-id: 0x6f9ee2e9"
        echo "device: $SYSTEM"
        echo "unit: sectors"
        echo "sector-size: 512"
        echo ""
        echo "${SYSTEM}1 : start=        2048, size=    16777216, type=83"
        echo "${SYSTEM}2 : start=    16779264, size=     4194304, type=82"
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

if [ -s "$IDB.txz" ]; then
  INDEX_DB="$MOUNT/usr/syno/synoman/indexdb"
  mkdir -p "$INDEX_DB"
fi

LABEL="1.44.1-42218"
OFFSET="1048576"    # 2048 * 512
NUMBLOCKS="2097152" # (16777216 * 512) / 4096
MSG="Installing system partition..."

fakeroot -- bash -c "set -Eeu;\
  [ -s $HDP.txz ] && tar xpfJ $HDP.txz --absolute-names -C $MOUNT/;\
  [ -s $IDB.txz ] && tar xpfJ $IDB.txz --absolute-names -C $INDEX_DB/;\
  tar xpfJ $HDA.txz --absolute-names --skip-old-files -C $MOUNT/;\
  printf '%b%s%b' '\E[1;34m❯ \E[1;36m' 'Install: $MSG' '\E[0m\n';\
  mke2fs -q -t ext4 -b 4096 -d $MOUNT/ -L $LABEL -F -E offset=$OFFSET $SYSTEM $NUMBLOCKS"

rm -rf "$MOUNT"
echo "$BASE" > "$STORAGE/dsm.ver"

if [[ "$URL" == "file://$STORAGE/$BASE.pat" ]]; then
  rm -f "$PAT"
else
  mv -f "$PAT" "$STORAGE/$BASE.pat"
fi

mv -f "$BOOT" "$STORAGE/$BASE.boot.img"
rm -rf "$TMP"

html "Booting DSM instance..."
sleep 1.2

return 0
