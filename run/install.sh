#!/usr/bin/env bash
set -Eeuo pipefail

# Display wait message
/run/server.sh 5000 install &

# Download the required files from the Synology website
DL="https://global.synologydownload.com/download/DSM"

if [ -z "$URL" ]; then

  if [ "$ARCH" == "amd64" ]; then
    URL="$DL/release/7.2.1/69057-1/DSM_VirtualDSM_69057.pat"
  else
    URL="$DL/release/7.0.1/42218/DSM_VirtualDSM_42218.pat"
  fi

fi

# Check if output is to interactive TTY
if [ -t 1 ]; then
  PROGRESS="--progress=bar:noscroll"
else
  PROGRESS="--progress=dot:giga"
fi

BASE=$(basename "$URL" .pat)

rm -f "$STORAGE"/"$BASE".pat
rm -f "$STORAGE"/"$BASE".agent
rm -f "$STORAGE"/"$BASE".boot.img
rm -f "$STORAGE"/"$BASE".system.img

TMP="/tmp/dsm"
FS=$(stat -f -c %T "$STORAGE")
[[ "$FS" == "ext"* ]] && TMP="$STORAGE/tmp"
rm -rf "$TMP" && mkdir -p "$TMP"

# Check free diskspace
MIN_SPACE=5842450944
SPACE=$(df --output=avail -B 1 "$TMP" | tail -n 1)
(( MIN_SPACE > SPACE )) && error "Not enough free space for installation." && exit 95

[[ "${DEBUG}" == [Yy1]* ]] && set -x

RDC="$STORAGE/dsm.rd"

if [ ! -f "${RDC}" ]; then

  info "Install: Downloading installer..."

  RD="$TMP/rd.gz"
  POS="65627648-71021835"
  VERIFY="b4215a4b213ff5154db0488f92c87864"
  LOC="$DL/release/7.0.1/42218/DSM_VirtualDSM_42218.pat"

  { curl -r "$POS" -sfk -o "$RD" "$LOC"; rc=$?; } || :
  (( rc != 0 )) && error "Failed to download $LOC, reason: $rc" && exit 60

  SUM=$(md5sum "$RD" | cut -f 1 -d " ")

  if [ "$SUM" != "$VERIFY" ]; then

    PAT="/install.pat"
    rm "$RD"
    rm -f "$PAT"

    { wget "$LOC" -O "$PAT" -q --no-check-certificate --show-progress "$PROGRESS"; rc=$?; } || :
    (( rc != 0 )) && error "Failed to download $LOC, reason: $rc" && exit 60

    tar --extract --file="$PAT" --directory="$(dirname "${RD}")"/. "$(basename "${RD}")"
    rm "$PAT"

  fi

  cp "$RD" "$RDC"

fi

if [ -f "${RDC}" ]; then

  { xz -dc <"$RDC" >"$TMP/rd" 2>/dev/null; rc=$?; } || :
  (( rc != 1 )) && error "Failed to unxz $RDC, reason $rc" && exit 91

  { (cd "$TMP" && cpio -idm <"$TMP/rd" 2>/dev/null); rc=$?; } || :
  (( rc != 0 )) && error "Failed to cpio $RDC, reason $rc" && exit 92

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

{ wget "$URL" -O "$PAT" -q --no-check-certificate --show-progress "$PROGRESS"; rc=$?; } || :

(( rc != 0 )) && error "Failed to download $URL, reason: $rc" && exit 69
[ ! -f "$PAT" ] && error "Failed to download $URL" && exit 69

SIZE=$(stat -c%s "$PAT")

if ((SIZE<250000000)); then
  error "The specified PAT file is probably an update pack as it's too small." && exit 62
fi

if { tar tf "$PAT"; } >/dev/null 2>&1; then

  info "Install: Extracting downloaded image..."
  tar xpf "$PAT" -C "$TMP/."

else

  if [ "$ARCH" != "amd64" ]; then

    info "Install: Installing QEMU..."

    export DEBCONF_NOWARNINGS="yes"
    export DEBIAN_FRONTEND="noninteractive"

    apt-get -qq update
    apt-get -qq --no-install-recommends -y install qemu-user > /dev/null

  fi

  info "Install: Extracting downloaded image..."

  export LD_LIBRARY_PATH="/run/extract"

  if [ "$ARCH" == "amd64" ]; then
    { /run/extract/syno_extract_system_patch "$PAT" "$TMP/."; rc=$?; } || :
  else
    { qemu-x86_64 /run/extract/syno_extract_system_patch "$PAT" "$TMP/."; rc=$?; } || :
  fi

  export LD_LIBRARY_PATH=""

  (( rc != 0 )) && error "Failed to extract PAT file, reason $rc" && exit 63

fi

HDA="$TMP/hda1"
IDB="$TMP/indexdb"
PKG="$TMP/packages"
HDP="$TMP/synohdpack_img"

[ ! -f "$HDA.tgz" ] && error "The PAT file contains no OS image." && exit 64

BOOT=$(find "$TMP" -name "*.bin.zip")
[ ! -f "$BOOT" ] && error "The PAT file contains no boot image." && exit 67

BOOT=$(echo "$BOOT" | head -c -5)
unzip -q -o "$BOOT".zip -d "$TMP"

[[ "${ALLOCATE}" == [Zz]* ]] && info "Install: Allocating diskspace..."

SYSTEM="$TMP/sys.img"
SYSTEM_SIZE=4954537983

# Check free diskspace
SPACE=$(df --output=avail -B 1 "$TMP" | tail -n 1)
(( SYSTEM_SIZE > SPACE )) && error "Not enough free space to create a 4 GB system disk." && exit 87

if ! fallocate -l "${SYSTEM_SIZE}" "${SYSTEM}"; then
  if ! truncate -s "${SYSTEM_SIZE}" "${SYSTEM}"; then
    rm -f "${SYSTEM}" && error "Could not allocate a file for the system disk." && exit 88
  fi
fi

if [[ "${ALLOCATE}" == [Zz]* ]]; then
  info "Install: Preallocating 4 GB of diskspace..."
  dd if=/dev/urandom of="${SYSTEM}" count="${SYSTEM_SIZE}" bs=1M iflag=count_bytes status=none
fi

# Check if file exists
[ ! -f "${SYSTEM}" ] && error "System disk does not exist ($SYSTEM)" && exit 89

# Check the filesize
SIZE=$(stat -c%s "${SYSTEM}")
[[ SIZE -ne SYSTEM_SIZE ]] && rm -f "${SYSTEM}" && error "System disk has the wrong size: ${SIZE}" && exit 90

PART="$TMP/partition.fdisk"

{       echo "label: dos"
        echo "label-id: 0x6f9ee2e9"
        echo "device: ${SYSTEM}"
        echo "unit: sectors"
        echo "sector-size: 512"
        echo ""
        echo "${SYSTEM}1 : start=        2048, size=     4980480, type=83"
        echo "${SYSTEM}2 : start=     4982528, size=     4194304, type=82"
} > "$PART"

sfdisk -q "$SYSTEM" < "$PART"

info "Install: Extracting system partition..."

MOUNT="$TMP/system"
rm -rf "$MOUNT" && mkdir -p "$MOUNT"

mv "$HDA.tgz" "$HDA.txz"
tar xpfJ "$HDA.txz" --absolute-names -C "$MOUNT/"

[ -d "$PKG" ] && mv "$PKG/" "$MOUNT/.SynoUpgradePackages/"
rm -f "$MOUNT/.SynoUpgradePackages/ActiveInsight-"*

[ -f "$HDP.txz" ] && tar xpfJ "$HDP.txz" --absolute-names -C "$MOUNT/"
[ -f "$IDB.txz" ] && tar xpfJ "$IDB.txz" --absolute-names -C "$MOUNT/usr/syno/synoman/indexdb/"

# Install Agent

LOC="$MOUNT/usr/local/bin"
mkdir -p "$LOC"
cp /agent/agent.sh "$LOC/agent.sh"
chmod 755 "$LOC/agent.sh"

LOC="$MOUNT/usr/local/etc/rc.d"
mkdir -p "$LOC"
cp /agent/service.sh "$LOC/agent.sh"
chmod 755 "$LOC/agent.sh"

info "Install: Installing system partition..."

LABEL="1.44.1-42218"
OFFSET="1048576" # 2048 * 512
NUMBLOCKS="622560" # (4980480 * 512) / 4096

mke2fs -q -t ext4 -b 4096 -d "$MOUNT/" -L "$LABEL" -F -E "offset=$OFFSET" "$SYSTEM" "$NUMBLOCKS"

rm -rf "$MOUNT"

echo "$BASE" > "$STORAGE"/dsm.ver

# Check free diskspace
SPACE=$(df --output=avail -B 1 "$STORAGE" | tail -n 1)
(( MIN_SPACE > SPACE )) && error "Not enough free space in storage folder." && exit 94

mv -f "$PAT" "$STORAGE"/"$BASE".pat
mv -f "$BOOT" "$STORAGE"/"$BASE".boot.img
mv -f "$SYSTEM" "$STORAGE"/"$BASE".system.img

rm -rf "$TMP"

{ set +x; } 2>/dev/null
[[ "${DEBUG}" == [Yy1]* ]] && echo

return 0
