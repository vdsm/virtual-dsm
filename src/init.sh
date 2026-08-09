#!/usr/bin/env bash
set -Eeuo pipefail

trap 'error "Status $? while: $BASH_COMMAND (line $LINENO/$BASH_LINENO)"' ERR
enabled "${TRACE:-}" && set -o functrace && trap 'echo "# $BASH_COMMAND" >&2' DEBUG

[ ! -f "/run/entry.sh" ] && error "Script must be run inside the container!" && exit 11
[ "$(id -u)" -ne "0" ] && error "Script must be executed with root privileges." && exit 12

# Docker environment variables

: "${KVM:="Y"}"            # KVM acceleration
: "${BOOT:=""}"            # Path of ISO file
: "${AUDIO:="N"}"          # Stream guest audio
: "${DEBUG:="N"}"          # Disable debugging
: "${MACHINE:="q35"}"      # Machine selection
: "${ALLOCATE:=""}"        # Preallocate diskspace
: "${ARGUMENTS:=""}"       # Extra QEMU parameters
: "${CPU_CORES:="2"}"      # Amount of CPU cores
: "${RAM_SIZE:="2G"}"      # Maximum RAM amount
: "${RAM_CHECK:="Y"}"      # Check available RAM
: "${DISK_SIZE:="64G"}"    # Initial data disk size
: "${BOOT_MODE:=""}"       # Boot system with UEFI
: "${BOOT_INDEX:="9"}"     # Boot index of CD drive
: "${STORAGE:="/storage"}" # Storage folder location
: "${CONNECTIONS:="4"}"    # Download connection count

detectEngine() {

  if [ -f "/run/.containerenv" ]; then
    ENGINE="${container:-}"

    if [[ "${ENGINE,,}" == *"podman"* ]]; then
      ENGINE="Podman"
    else
      [ -z "$ENGINE" ] && ENGINE="Kubernetes"
    fi
  elif [ -f "/.dockerenv" ]; then
    ENGINE="Docker"
  fi

  return 0
}

detectRootless() {

  local uid_map

  uid_map=$(awk '{$1=$1; print}' /proc/self/uid_map 2>/dev/null || true)

  # An identity UID mapping means real container root; any remapped range is a
  # rootless/user-namespace environment.
  if [[ "$uid_map" == "0 0 4294967295" ]]; then
    ROOTLESS="N"
  else
    ROOTLESS="Y"
  fi

  return 0
}

checkPrivileged() {

  local cap_bnd
  local last_cap
  # Get the capability bounding set
  cap_bnd=$(grep '^CapBnd:' /proc/$$/status | awk '{print $2}')
  cap_bnd=$(printf "%d" "0x${cap_bnd}")

  # Get the last capability number
  last_cap=$(cat /proc/sys/kernel/cap_last_cap)

  # Calculate the maximum capability value
  local max_cap=$(((1 << (last_cap + 1)) - 1))

  # A privileged container exposes the complete kernel capability bounding set,
  # not merely the smaller set Docker grants by default.
  if [ "$cap_bnd" -eq "$max_cap" ]; then
    PRIVILEGED="Y"
  fi

  return 0
}

checkCores() {

  CPU_CORES=$(strip "$CPU_CORES")
  [ -z "$CPU_CORES" ] && CPU_CORES=2
  [[ "${CPU_CORES,,}" == "max" ]] && CPU_CORES="$CORES"
  [[ "${CPU_CORES,,}" == "half" ]] && CPU_CORES=$(( CORES / 2 ))
  [ -z "${CPU_CORES##*[!0-9]*}" ] && error "Invalid amount of CPU_CORES: $CPU_CORES" && exit 15
  [ "$CPU_CORES" -lt "1" ] && CPU_CORES=1

  if [ "$CPU_CORES" -gt "$CORES" ]; then
    warn "The amount for CPU_CORES (${CPU_CORES}) exceeds the amount of logical cores available (${CORES}) and will be limited."
    CPU_CORES="$CORES"
  fi

  return 0
}

checkSockets() {

  local lscpu_out
  lscpu_out=$(lscpu 2>/dev/null || true)

  if grep -qi "socket(s)" <<< "$lscpu_out"; then
    SOCKETS=$(grep -m 1 -i 'socket(s)' <<< "$lscpu_out" | awk '{print $2}')
    [ -z "${SOCKETS##*[!0-9]*}" ] && SOCKETS=1
    [ "$SOCKETS" -lt "1" ] && SOCKETS=1
  fi

  return 0
}

checkHost() {

  if [[ "${FS,,}" == "ecryptfs" || "${FS,,}" == "tmpfs" ]]; then
    DISK_IO="threads"
    DISK_CACHE="writeback"
  fi

  if [[ "${BOOT_MODE:-}" == "windows"* ]]; then
    if [[ "${FS,,}" == "btrfs" ]]; then
      warn "you are using the BTRFS filesystem for /storage, this might introduce issues with Windows Setup!"
    fi
  fi

  return 0
}

checkStorage() {

  # Check system

  QEMU_DIR="/run/shm"

  if [ ! -d "/dev/shm" ]; then
    error "Directory /dev/shm not found!" && exit 14
  else
    # Keep runtime sockets and PID files on shared memory even on images where
    # /run/shm is absent but /dev/shm is available.
    [ ! -d "$QEMU_DIR" ] && ln -s /dev/shm "$QEMU_DIR"
  fi

  QEMU_PID="$QEMU_DIR/qemu.pid"

  # Check folder

  if [[ "${STORAGE,,}" != "/storage" ]]; then
    if ! mkdir -p -- "$STORAGE"; then
      error "Cannot create storage folder ($STORAGE)!" && exit 13
    fi
  fi

  if [ ! -d "$STORAGE" ]; then
    error "Storage folder ($STORAGE) not found!" && exit 13
  fi

  if [ ! -w "$STORAGE" ]; then
    msg="Storage folder ($STORAGE) is not writeable!"
    msg+=" If SELinux is active, you need to add the \":Z\" flag to the bind mount."
    error "$msg" && exit 13
  fi

  return 0
}

checkKvm() {

  # Check KVM support

  if [[ "${PLATFORM,,}" == "x64" ]]; then
    TARGET="amd64"
  else
    TARGET="arm64"
  fi

  if disabled "$KVM"; then
    warn "KVM acceleration is disabled, this will cause the machine to run about 10 times slower!"
  else
    if [[ "${ARCH,,}" != "$TARGET" ]]; then
      KVM="N"
      warn "your CPU architecture is ${ARCH^^} and cannot provide KVM acceleration for ${PLATFORM^^} instructions, so the machine will run about 10 times slower."
    fi
  fi

  if ! disabled "$KVM"; then

    KVM_ERR=""

    if [ ! -e /dev/kvm ]; then
      KVM_ERR="(/dev/kvm is missing)"
    else
      if ! sh -c 'echo -n > /dev/kvm' &> /dev/null; then
        KVM_ERR="(/dev/kvm is unwriteable)"
      else
        if [[ "${PLATFORM,,}" == "x64" ]]; then
          flags=$(sed -ne '/^flags/s/^.*: //p' /proc/cpuinfo)
          if ! grep -qw "vmx\|svm" <<< "$flags"; then
            KVM_ERR="(not enabled in BIOS)"
          fi
        fi
      fi
    fi

    if [ -n "$KVM_ERR" ]; then
      KVM="N"
      if [[ "$OSTYPE" =~ ^darwin ]]; then
        warn "you are using macOS which has no KVM support, so the machine will run about 10 times slower."
      else
        kernel=$(uname -a)
        case "${kernel,,}" in
          *"microsoft"* )
            error "Please bind '/dev/kvm' as a volume in the optional container settings when using Docker Desktop." ;;
          *"synology"* )
            error "Please make sure that Synology VMM (Virtual Machine Manager) is installed and that '/dev/kvm' is binded to this container." ;;
          *)
            error "KVM acceleration is not available $KVM_ERR, this will cause the machine to run about 10 times slower."
            error "See the FAQ for possible causes, or disable acceleration by adding the \"KVM=N\" variable (not recommended)." ;;
        esac
        # DEBUG mode deliberately permits a slow TCG fallback so diagnostics can
        # continue even when KVM setup is broken.
        enabled "$DEBUG" || exit 88
      fi
    fi

  fi

  return 0
}

# Sanitize variables
STORAGE=$(strip "$STORAGE")
MACHINE=$(strip "${MACHINE,,}")
DISK_SIZE=$(strip "$DISK_SIZE")
BOOT_INDEX=$(strip "$BOOT_INDEX")
BOOT_MODE=$(strip "${BOOT_MODE,,}")
CONNECTIONS=$(strip "$CONNECTIONS")

# Helper variables
ROOTLESS="N"
PRIVILEGED="N"
ENGINE="Docker"
PROCESS="${APP,,}"
PROCESS="${PROCESS// /-}"

# Detect runtime
detectEngine
detectRootless

echo "❯ Starting $APP for $ENGINE v$(</etc/version)..."
echo "❯ For support visit $SUPPORT"

checkPrivileged

INFO="/run/shm/msg.html"
PAGE="/run/shm/index.html"
TEMPLATE="/var/www/index.html"
FOOTER1="$APP for $ENGINE v$(</etc/version)"
FOOTER2="<a href='$SUPPORT'>$SUPPORT</a>"

SOCKETS=1
CPU=$(cpu)
SYS=$(uname -r)
ARCH=$(dpkg --print-architecture)
CORES=$(grep -c '^processor' /proc/cpuinfo)
IFS=. read -r KERNEL MINOR _ <<< "$SYS"

checkSockets
checkCores
checkStorage
getMemoryInfo

# Print system info
SYS="${SYS/-generic/}"
FS=$(stat -f -c %T "$STORAGE")
FS="${FS/UNKNOWN //}"
FS="${FS/ext2\/ext3/ext4}"
FS=$(echo "$FS" | sed 's/[)(]//g')
SPACE=$(df --output=avail -B 1 "$STORAGE" | tail -n 1)
SPACE_GB=$(formatBytes "$SPACE" "down")
AVAIL_MEM=$(formatBytes "$RAM_AVAIL" "down")
TOTAL_MEM=$(formatBytes "$RAM_TOTAL" "up")

echo "❯ CPU: ${CPU} | RAM: ${AVAIL_MEM/ GB/}/$TOTAL_MEM | DISK: $SPACE_GB (${FS}) | KERNEL: ${SYS}"
echo

# Check compatibility

checkHost
checkKvm

# Cleanup dirs
rm -rf "$STORAGE/tmp"

# Cleanup files
rm -f "$QEMU_DIR"/{qemu.*,*.{pid,sock,pipe}}

# Helper processes terminated during shutdown
# Store variable names rather than current values because many helper PID paths
# are assigned later during startup and resolved only during cleanup.
HELPER_PIDS=(
  TPM_PID
  WSD_PID
  AUX_PID
  WEB_PID
  AUDIO_PID
  PASST_PID
  DNSMASQ_PID
  CONSOLE_PID
  BALLOONING_PID
)

return 0
