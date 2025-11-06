#!/usr/bin/env bash
set -Eeuo pipefail

trap 'error "Status $? while: $BASH_COMMAND (line $LINENO/$BASH_LINENO)"' ERR
[[ "${TRACE:-}" == [Yy1]* ]] && set -o functrace && trap 'echo "# $BASH_COMMAND" >&2' DEBUG

[ ! -f "/run/entry.sh" ] && error "Script must be run inside the container!" && exit 11
[ "$(id -u)" -ne "0" ] && error "Script must be executed with root privileges." && exit 12

# Docker environment variables

: "${TZ:=""}"              # System timezone
: "${KVM:="Y"}"            # KVM acceleration
: "${DEBUG:="N"}"          # Disable debugging mode
: "${COUNTRY:=""}"         # Country code for mirror
: "${CONSOLE:="N"}"        # Disable console mode
: "${ALLOCATE:=""}"        # Preallocate diskspace
: "${ARGUMENTS:=""}"       # Extra QEMU parameters
: "${CPU_CORES:="2"}"      # Amount of CPU cores
: "${RAM_SIZE:="2G"}"      # Maximum RAM amount
: "${RAM_CHECK:="Y"}"      # Check available RAM
: "${DISK_SIZE:="16G"}"    # Initial data disk size
: "${STORAGE:="/storage"}" # Storage folder location

# Helper variables

ROOTLESS="N"
PRIVILEGED="N"
ENGINE="Docker"
PROCESS="${APP,,}"
PROCESS="${PROCESS// /-}"

if [ -f "/run/.containerenv" ]; then
  ENGINE="${container:-}"
  if [[ "${ENGINE,,}" == *"podman"* ]]; then
    ROOTLESS="Y"
    ENGINE="Podman"
  else
    [ -z "$ENGINE" ] && ENGINE="Kubernetes"
  fi
fi

echo "❯ Starting $APP for $ENGINE v$(</run/version)..."
echo "❯ For support visit $SUPPORT"

# Get the capability bounding set
CAP_BND=$(grep '^CapBnd:' /proc/$$/status | awk '{print $2}')
CAP_BND=$(printf "%d" "0x${CAP_BND}")

# Get the last capability number
LAST_CAP=$(cat /proc/sys/kernel/cap_last_cap)

# Calculate the maximum capability value
MAX_CAP=$(((1 << (LAST_CAP + 1)) - 1))

if [ "${CAP_BND}" -eq "${MAX_CAP}" ]; then
  ROOTLESS="N"
  PRIVILEGED="Y"
fi

INFO="/run/shm/msg.html"
PAGE="/run/shm/index.html"
TEMPLATE="/var/www/index.html"
FOOTER1="$APP for $ENGINE v$(</run/version)"
FOOTER2="<a href='$SUPPORT'>$SUPPORT</a>"

CPU=$(cpu)
SYS=$(uname -r)
HOST=$(hostname -s)
KERNEL=$(echo "$SYS" | cut -b 1)
MINOR=$(echo "$SYS" | cut -d '.' -f2)
ARCH=$(dpkg --print-architecture)
CORES=$(grep -c '^processor' /proc/cpuinfo)

if ! grep -qi "socket(s)" <<< "$(lscpu)"; then
  SOCKETS=1
else
  SOCKETS=$(lscpu | grep -m 1 -i 'socket(s)' | awk '{print $(2)}')
fi

CPU_CORES="${CPU_CORES// /}"
[[ "${CPU_CORES,,}" == "max" ]] && CPU_CORES="$CORES"
[[ "${CPU_CORES,,}" == "half" ]] && CPU_CORES=$(( CORES / 2 ))
[[ "${CPU_CORES,,}" == "0" ]] && CPU_CORES="1"
[ -n "${CPU_CORES//[0-9 ]}" ] && error "Invalid amount of CPU_CORES: $CPU_CORES" && exit 15

if [ "$CPU_CORES" -gt "$CORES" ]; then
  warn "The amount for CPU_CORES (${CPU_CORES}) exceeds the amount of logical cores available, so will be limited to ${CORES}."
  CPU_CORES="$CORES"
fi

# Check system

if [ ! -d "/dev/shm" ]; then
  error "Directory /dev/shm not found!" && exit 14
else
  [ ! -d "/run/shm" ] && ln -s /dev/shm /run/shm
fi

# Check folder

if [[ "${STORAGE,,}" != "/storage" ]]; then
  mkdir -p "$STORAGE"
fi

if [ ! -d "$STORAGE" ]; then
  error "Storage folder ($STORAGE) not found!" && exit 13
fi

if [ ! -w "$STORAGE" ]; then
  msg="Storage folder ($STORAGE) is not writeable!"
  msg+=" If SELinux is active, you need to add the \":Z\" flag to the bind mount."
  error "$msg" && exit 13
fi

# Check filesystem
FS=$(stat -f -c %T "$STORAGE")

if [[ "${FS,,}" == "ecryptfs" || "${FS,,}" == "tmpfs" ]]; then
  DISK_IO="threads"
  DISK_CACHE="writeback"
fi

# Read memory
RAM_SPARE=500000000
RAM_AVAIL=$(free -b | grep -m 1 Mem: | awk '{print $7}')
RAM_TOTAL=$(free -b | grep -m 1 Mem: | awk '{print $2}')

RAM_SIZE="${RAM_SIZE// /}"
[ -z "$RAM_SIZE" ] && error "RAM_SIZE not specified!" && exit 16

if [[ "${RAM_SIZE,,}" != "max" && "${RAM_SIZE,,}" != "half" ]]; then

  if [ -z "${RAM_SIZE//[0-9. ]}" ]; then
    [ "${RAM_SIZE%%.*}" -lt "130" ] && RAM_SIZE="${RAM_SIZE}G" || RAM_SIZE="${RAM_SIZE}M"
  fi

  RAM_SIZE=$(echo "${RAM_SIZE^^}" | sed 's/MB/M/g;s/GB/G/g;s/TB/T/g')
  ! numfmt --from=iec "$RAM_SIZE" &>/dev/null && error "Invalid RAM_SIZE: $RAM_SIZE" && exit 16
  RAM_WANTED=$(numfmt --from=iec "$RAM_SIZE")
  [ "$RAM_WANTED" -lt "136314880 " ] && error "RAM_SIZE is too low: $RAM_SIZE" && exit 16

fi

# Print system info
SYS="${SYS/-generic/}"
FS="${FS/UNKNOWN //}"
FS="${FS/ext2\/ext3/ext4}"
FS=$(echo "$FS" | sed 's/[)(]//g')
SPACE=$(df --output=avail -B 1 "$STORAGE" | tail -n 1)
SPACE_GB=$(formatBytes "$SPACE" "down")
AVAIL_MEM=$(formatBytes "$RAM_AVAIL" "down")
TOTAL_MEM=$(formatBytes "$RAM_TOTAL" "up")

echo "❯ CPU: ${CPU} | RAM: ${AVAIL_MEM/ GB/}/$TOTAL_MEM | DISK: $SPACE_GB (${FS}) | KERNEL: ${SYS}..."
echo

# Check KVM support

if [[ "${PLATFORM,,}" == "x64" ]]; then
  TARGET="amd64"
else
  TARGET="arm64"
fi

if [[ "$KVM" == [Nn]* ]]; then
  warn "KVM acceleration is disabled, this will cause the machine to run about 10 times slower!"
else
  if [[ "${ARCH,,}" != "$TARGET" ]]; then
    KVM="N"
    warn "your CPU architecture is ${ARCH^^} and cannot provide KVM acceleration for ${PLATFORM^^} instructions, so the machine will run about 10 times slower."
  fi
fi

if [[ "$KVM" != [Nn]* ]]; then

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
        if ! grep -qw "sse4_2" <<< "$flags"; then
          error "Your CPU does not have the SSE4 instruction set that Virtual DSM requires!"
          [[ "$DEBUG" != [Yy1]* ]] && exit 88
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
      [[ "$DEBUG" != [Yy1]* ]] && exit 88
    fi
  fi

fi

# Cleanup files
rm -f /run/shm/qemu.*
rm -f /run/shm/dsm.url

# Cleanup dirs
rm -rf /tmp/dsm
rm -rf "$STORAGE/tmp"

return 0
