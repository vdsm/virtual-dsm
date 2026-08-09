#!/usr/bin/env bash
set -Eeuo pipefail

: "${TZ:=""}"         # System timezone
: "${COUNTRY:=""}"    # Country code for mirror
: "${URL:=""}"        # URL of the PAT file to be downloaded.

TZ=$(strip "$TZ")
COUNTRY=$(strip "$COUNTRY")

checkDsmFilesystem() {

  local fs="$1"

  if [[ "${fs,,}" == "overlay"* && "${ENGINE,,}" == "docker" ]]; then
    warn "the filesystem of $STORAGE is OverlayFS, this usually means it was binded to an invalid path!"
  fi

  if [[ "${fs,,}" == "fuse"* ]]; then
    warn "the filesystem of $STORAGE is FUSE, this extra layer will negatively affect performance!"
  fi

  if [[ "${fs,,}" == "ecryptfs" || "${fs,,}" == "tmpfs" ]]; then
    warn "the filesystem of $STORAGE is $fs, which does not support O_DIRECT mode, adjusting settings..."
  fi

  if [[ "${fs,,}" == "fat"* || "${fs,,}" == "vfat"* || "${fs,,}" == "msdos"* ]]; then
    error "Unable to install on $fs filesystems, please use a different filesystem for /storage."
    return 61
  fi

  return 0
}

checkDsmSpace() {

  local rootSpace=536870912
  local minSpace=15032385536
  local space available

  space=$(df --output=avail -B 1 / | tail -n 1) || return $?
  available=$(formatBytes "$space" "down") || return $?

  if (( rootSpace > space )); then
    error "Not enough free space inside the container, have $available available but need at least 500 MB."
    return 96
  fi

  space=$(df --output=avail -B 1 "$STORAGE" | tail -n 1) || return $?
  available=$(formatBytes "$space") || return $?

  if (( minSpace > space )); then
    error "Not enough free space for installation in $STORAGE, have $available available but need at least 14 GB."
    return 94
  fi

  return 0
}

downloadPat() {

  local pat="$1"
  local msg err

  if [[ "$URL" == "file://"* ]]; then
    msg="Copying DSM"
    err="Failed to copy ${URL:7}"
    info "Install: Copying installation image..."
  else
    msg="Downloading DSM"
    err="Failed to download $URL"
    info "Install: Downloading $BASE.pat..."
  fi

  html "$msg..." || return $?
  rm -f "$pat" || return $?

  if [[ "$URL" == "file://"* ]]; then

    if [ ! -f "${URL:7}" ]; then
      error "File '${URL:7}' does not exist!"
      return 65
    fi

    cp "${URL:7}" "$pat" || return $?

  else

    local size=0
    local reason=""
    local output=""
    local log rc
    local -a progress=()

    log=$(mktemp) || return $?

    [[ "${URL,,}" == *"_72806.pat" ]] && size=361010261
    [[ "${URL,,}" == *"_69057.pat" ]] && size=363837333
    [[ "${URL,,}" == *"_42218.pat" ]] && size=379637760

    # Use Wget's progress bar in a terminal and progress.sh in container logs.
    if [ -t 1 ]; then
      progress=( --show-progress --progress=bar:noscroll )
    else
      output="log"
    fi

    /run/progress.sh "$pat" "$size" "$msg ([P])..." "$output" 52428800 &

    {
      LC_ALL=C wget "$URL" -O "$pat" --no-verbose --no-check-certificate \
        --timeout=30 --no-http-keep-alive "${progress[@]}" \
        --output-file="$log"
      rc=$?
    } || :

    fKill "progress.sh"

    if (( rc != 0 )); then
      reason=$(sed -n \
        -e 's/^wget: //p' \
        -e 's/^[0-9-]\{10\} [0-9:]\{8\} ERROR //p' \
        "$log" | tail -n 1) || return $?
    fi

    rm -f "$log" || return $?

    if (( rc == 3 )); then
      error "$err because the file could not be written (disk full?)."
      return 69
    elif (( rc != 0 )); then
      if [ -n "$reason" ]; then
        error "$err: ${reason%.}."
      else
        error "$err with exit status $rc."
      fi
      return 69
    fi

  fi

  if [ ! -s "$pat" ]; then
    error "$err"
    return 69
  fi

  return 0
}

extractPat() {

  local pat="$1"
  local tmp="$2"
  local size="$3"
  local msg="Extracting installation image..."
  local rc

  info "Install: $msg" && html "$msg" || return $?
  /run/progress.sh "$tmp" "$size" "$msg ([P])..." &

  # Newer PAT files are normal tar archives; older encrypted/proprietary forms
  # require the bundled extractor as a compatibility fallback.
  if { tar tf "$pat"; } >/dev/null 2>&1; then

    tar xpf "$pat" -C "$tmp/." || {
      rc=$?
      fKill "progress.sh"
      return "$rc"
    }

  else

    { (cd "$tmp" && python3 /run/extract.py -i "$pat" -d 2>/run/extract.log); rc=$?; } || :

    if (( rc != 0 )); then
      fKill "progress.sh"
      cat /run/extract.log
      error "Failed to extract PAT file, reason $rc"
      return 63
    fi

  fi

  fKill "progress.sh"
  return 0
}

createSystemImage() {

  local tmp="$1"
  local fs="$2"
  local msg="Preparing system partition..."

  info "Install: $msg" && html "$msg" || return $?

  # The PAT boot archive becomes the persistent QEMU boot disk after its
  # companion system partition has been assembled.
  BOOT=$(find "$tmp" -name "*.bin.zip" -print -quit) || return $?

  if [ -z "$BOOT" ]; then
    error "The PAT file contains no boot image."
    return 67
  fi

  if [ ! -s "$BOOT" ]; then
    error "The PAT boot image archive is empty."
    return 67
  fi

  unzip -q -o "$BOOT" -d "$tmp" || return $?
  BOOT="${BOOT%.zip}"

  SYSTEM="$STORAGE/$BASE.system.img"
  rm -f "$SYSTEM" || return $?

  # Check free diskspace
  local systemSize=10738466816
  local space available

  space=$(df --output=avail -B 1 "$STORAGE" | tail -n 1) || return $?
  available=$(formatBytes "$space") || return $?

  if (( systemSize > space )); then
    error "Not enough free space in $STORAGE to create a 10 GB system disk, have only $available available."
    return 97
  fi

  if ! touch "$SYSTEM"; then
    error "Could not create file $SYSTEM for the system disk."
    return 98
  fi

  setOwner "$SYSTEM" || warn "failed to set the owner for \"$SYSTEM\" !"

  if [[ "${fs,,}" == "btrfs" ]]; then
    { chattr +C "$SYSTEM"; } || :
    local attrs
    attrs=$(lsattr "$SYSTEM") || return $?
    if [[ "$attrs" != *"C"* ]]; then
      error "Failed to disable COW for system image $SYSTEM on ${fs^^} filesystem."
    fi
  fi

  if ! fallocate -l "$systemSize" "$SYSTEM" &>/dev/null; then
    if ! fallocate -l -x "$systemSize" "$SYSTEM"; then
      if ! truncate -s "$systemSize" "$SYSTEM"; then
        rm -f "$SYSTEM"
        error "Could not allocate file $SYSTEM for the system disk."
        return 98
      fi
    fi
  fi

  # Recreate Synology's expected DOS partition layout inside the fixed 10 GiB
  # system image before populating the ext4 root partition.
  local part="$tmp/partition.fdisk"
  local rc

  if {
    echo "label: dos"
    echo "label-id: 0x6f9ee2e9"
    echo "device: $SYSTEM"
    echo "unit: sectors"
    echo "sector-size: 512"
    echo ""
    echo "${SYSTEM}1 : start=        2048, size=    16777216, type=83"
    echo "${SYSTEM}2 : start=    16779264, size=     4194304, type=82"
  } > "$part"; then
    :
  else
    rc=$?
    return "$rc"
  fi

  sfdisk -q "$SYSTEM" < "$part" || return $?

  local mount="$tmp/system"
  rm -rf "$mount" || return $?

  if ! makeDir "$mount"; then
    error "Failed to create directory \"$mount\" !"
    return 93
  fi

  return 0
}

installSystemPartition() {

  local tmp="$1"
  local mount="$tmp/system"
  local msg="Extracting system partition..."

  info "Install: $msg" && html "$msg" || return $?

  local hda="$tmp/hda1"
  local idb="$tmp/indexdb"
  local pkg="$tmp/packages"
  local hdp="$tmp/synohdpack_img"

  if [ ! -s "$hda.tgz" ]; then
    error "The PAT file contains no OS image."
    return 64
  fi

  mv "$hda.tgz" "$hda.txz" || return $?

  if [ -d "$pkg" ]; then
    mv "$pkg/" "$mount/.SynoUpgradePackages/" || return $?
  fi

  rm -f "$mount/.SynoUpgradePackages/ActiveInsight-"* || return $?

  local indexDb="$mount/usr/syno/synoman/indexdb"

  if [ -s "$idb.txz" ]; then
    mkdir -p "$indexDb" || return $?
  fi

  local label="1.44.1-42218"
  local offset="1048576"    # 2048 * 512
  local numBlocks="2097152" # (16777216 * 512) / 4096
  local rc
  msg="Installing system partition..."

  # Build the ext4 filesystem directly from the extracted tree under fakeroot,
  # preserving archive ownership without mounting a loop device.
  if fakeroot -- bash -c "set -Eeu;\
    [ -s $hdp.txz ] && tar xpfJ $hdp.txz --absolute-names -C $mount/;\
    [ -s $idb.txz ] && tar xpfJ $idb.txz --absolute-names -C $indexDb/;\
    tar xpfJ $hda.txz --absolute-names --skip-old-files -C $mount/;\
    printf '%b%s%b' '\E[1;34m❯ \E[1;36m' 'Install: $msg' '\E[0m\n';\
    mke2fs -q -t ext4 -b 4096 -d $mount/ -L $label -F -E offset=$offset $SYSTEM $numBlocks"; then
    :
  else
    rc=$?
    return "$rc"
  fi

  rm -rf "$mount" || return $?
  return 0
}

checkSse42() {

  if disabled "$KVM" || [[ "${PLATFORM,,}" != "x64" ]]; then
    return 0
  fi

  if ! hasFlag "sse4_2"; then
    error "Your CPU does not have the SSE4 instruction set that Virtual DSM requires!"
    enabled "$DEBUG" || return 88
  fi

  return 0
}

sanitizePatBase() {

  local source="$1"
  local base

  base=$(basename "${source%%\?*}" .pat) || return 1
  printf -v base '%b' "${base//%/\\x}" || return 1
  base="${base//[!A-Za-z0-9._-]/_}"

  printf '%s' "$base"
}

finishDsmInstall() {

  local pat="$1"
  local tmp="$2"

  echo "$BASE" > "$STORAGE/dsm.ver" || return $?
  setOwner "$STORAGE/dsm.ver" || warn "failed to set the owner for \"$STORAGE/dsm.ver\" !"

  # Do not keep a second copy when the source PAT already lives in storage;
  # downloaded or externally mounted sources are cached for later reuse.
  if [[ "$URL" == "file://$STORAGE/$BASE.pat" ]]; then
    rm -f "$pat" || return $?
  else
    mv -f "$pat" "$STORAGE/$BASE.pat" || return $?
  fi

  if [ -f "$STORAGE/$BASE.pat" ]; then
    setOwner "$STORAGE/$BASE.pat" || warn "failed to set the owner for \"$STORAGE/$BASE.pat\" !"
  fi

  mv -f "$BOOT" "$STORAGE/$BASE.boot.img" || return $?
  setOwner "$STORAGE/$BASE.boot.img" || warn "failed to set the owner for \"$STORAGE/$BASE.boot.img\" !"

  rm -rf "$tmp" || return $?
  return 0
}

installDSM() {

  checkSse42 || return $?

  rm -f "$QEMU_DIR/dsm.url" || return $?
  rm -rf /tmp/dsm || return $?

  local patName="boot.pat"
  local patDir patFile

  # Persist the exact PAT base name so future starts reopen the matching boot,
  # system, and cached installation files.
  if [ -f "$STORAGE/dsm.ver" ]; then
    BASE=$(<"$STORAGE/dsm.ver") || return $?
    BASE="${BASE//[![:print:]]/}"
    [ -z "$BASE" ] && BASE="DSM_VirtualDSM_69057"
  else
    # Fallback for old installs
    BASE="DSM_VirtualDSM_42962"
  fi

  patDir=$(find / -maxdepth 1 -type d -iname "$patName" -print -quit) || return $?

  if [ ! -d "$patDir" ]; then
    patDir=$(find "$STORAGE" -maxdepth 1 -type d -iname "$patName" -print -quit) || return $?
  fi

  # A boot.pat directory bind represents already extracted boot and system
  # images and therefore takes precedence over PAT file or URL discovery.
  if [ -d "$patDir" ]; then
    BASE="DSM_VirtualDSM"
    URL="file://$patDir"

    if [[ ! -s "$STORAGE/$BASE.boot.img" || ! -s "$STORAGE/$BASE.system.img" ]]; then
      error "The bind $patDir maps to a file that does not exist!"
      return 65
    fi
  fi

  patFile=$(find / -maxdepth 1 -type f -iname "$patName" -print -quit) || return $?

  if [ ! -s "$patFile" ]; then
    patFile=$(find "$STORAGE" -maxdepth 1 -type f -iname "$patName" -print -quit) || return $?
  fi

  if [ -s "$patFile" ]; then
    BASE="DSM_VirtualDSM"
    URL="file://$patFile"
  fi

  URL=$(strip "$URL") || return $?

  # Derive a filesystem-safe identity from the URL only when no local boot.pat
  # source was supplied; preserve an existing system image identity if present.
  if [ -n "$URL" ] && [ ! -s "$patFile" ] && [ ! -d "$patDir" ]; then
    BASE=$(basename "$URL" .pat) || return $?

    if [ ! -s "$STORAGE/$BASE.system.img" ]; then
      BASE=$(sanitizePatBase "$URL") || return $?
    fi

    if [[ "${URL,,}" != "http"* && "${URL,,}" != "file:"* ]]; then
      if [ ! -s "$STORAGE/$BASE.pat" ]; then
        error "Invalid URL:  $URL"
        return 65
      fi

      URL="file://$STORAGE/$BASE.pat"
    fi
  fi

  # A complete matching image pair is the installation marker; the cached PAT
  # itself is optional after installation.
  if [[ -s "$STORAGE/$BASE.boot.img" && -s "$STORAGE/$BASE.system.img" ]]; then
    return 0  # Previous installation found
  fi

  html "Please wait while Virtual DSM is being installed..." || return $?

  local mirror=""
  local chinaMirror="https://cndl.synology.cn/download/DSM"
  local globalMirror="https://global.synologydownload.com/download/DSM"

  [[ "${URL,,}" == *"cndl.synology"* ]] && mirror="$chinaMirror"
  [[ "${URL,,}" == *"global.synology"* ]] && mirror="$globalMirror"

  # Honor an explicitly selected Synology mirror first, otherwise choose the
  # China or global endpoint from the detected country.
  if [ -z "$mirror" ]; then
    if [ -z "$COUNTRY" ]; then
      setCountry || return $?
    fi

    [ -z "$COUNTRY" ] && info "Warning: could not detect country to select mirror!"
    [[ "${COUNTRY^^}" == "CN" ]] && mirror="$chinaMirror" || mirror="$globalMirror"
  fi

  if [ -z "$URL" ]; then
    URL="$mirror/release/7.2.2/72806/DSM_VirtualDSM_72806.pat"
  fi

  if [ ! -s "$patFile" ]; then
    BASE=$(sanitizePatBase "$URL") || return $?
  fi

  if [[ "$URL" != "file://$STORAGE/$BASE.pat" ]]; then
    rm -f "$STORAGE/$BASE.pat" || return $?
  fi

  rm -f "$STORAGE/$BASE.agent" || return $?
  rm -f "$STORAGE/$BASE.boot.img" || return $?
  rm -f "$STORAGE/$BASE.system.img" || return $?

  # Check filesystem
  local fs
  fs=$(stat -f -c %T "$STORAGE") || return $?
  checkDsmFilesystem "$fs" || return $?

  local tmp

  # Extract beside storage on Unix filesystems to avoid container-space limits;
  # use /tmp for filesystems that cannot safely host the installer workspace.
  if [[ "${fs,,}" != "exfat"* && "${fs,,}" != "ntfs"* && "${fs,,}" != "unknown"* ]]; then
    tmp="$STORAGE/tmp"
    rm -rf "$tmp" || return $?

    if ! makeDir "$tmp"; then
      error "Failed to create directory \"$tmp\" !"
      return 93
    fi
  else
    tmp="/tmp/dsm"
    local tmpSpace=2147483648
    local space available

    space=$(df --output=avail -B 1 /tmp | tail -n 1) || return $?
    available=$(formatBytes "$space") || return $?

    if (( tmpSpace > space )); then
      error "Not enough free space inside the container, have $available available but need at least 2 GB."
      return 93
    fi

    rm -rf "$tmp" || return $?
    mkdir -p "$tmp" || return $?
  fi

  # Check free diskspace
  checkDsmSpace || return $?

  local pat="/$BASE.pat"
  downloadPat "$pat" || return $?

  local size
  size=$(stat -c%s "$pat") || return $?

  # Full Virtual DSM PAT files are substantially larger than update packs;
  # reject undersized inputs before attempting destructive image preparation.
  if (( size < 250000000 )); then
    error "The specified PAT file is probably an update pack as it's too small."
    return 62
  fi

  extractPat "$pat" "$tmp" "$size" || return $?
  createSystemImage "$tmp" "$fs" || return $?
  installSystemPartition "$tmp" || return $?
  finishDsmInstall "$pat" "$tmp" || return $?

  return 0
}

installDSM || exit $?
return 0
