#!/usr/bin/env bash
set -Eeuo pipefail

trap 'error "Status $? while: $BASH_COMMAND (line $LINENO/$BASH_LINENO)"' ERR
[[ "${TRACE:-}" == [Yy1]* ]] && set -o functrace && trap 'echo "# $BASH_COMMAND" >&2' DEBUG

[ ! -f "/run/entry.sh" ] && error "Script must be run inside the container!" && exit 11
[ "$(id -u)" -ne "0" ] && error "Script must be executed with root privileges." && exit 12

# Docker environment variables

: "${TZ:=""}"              # System local timezone
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

PODMAN="N"
ENGINE="Docker"
PROCESS="${APP,,}"
PROCESS="${PROCESS// /-}"

if [ -f "/run/.containerenv" ]; then
  PODMAN="Y"
  ENGINE="Podman"
fi

echo "❯ Starting $APP for $ENGINE v$(</run/version)..."
echo "❯ For support visit $SUPPORT"

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
[ -n "${CPU_CORES//[0-9 ]}" ] && error "Invalid amount of CPU_CORES: $CPU_CORES" && exit 15

if [ "$CPU_CORES" -gt "$CORES" ]; then
  warn "The amount for CPU_CORES (${CPU_CORES}) exceeds the amount of physical cores, so will be limited to ${CORES}."
  CPU_CORES="$CORES"
fi

# Check system

if [ ! -d "/dev/shm" ]; then
  error "Directory /dev/shm not found!" && exit 14
else
  [ ! -d "/run/shm" ] && ln -s /dev/shm /run/shm
fi

# Check folder

if [[ "${COMMIT:-}" == [Yy1]* ]]; then
  STORAGE="/local"
  mkdir -p "$STORAGE"
fi

if [ ! -d "$STORAGE" ]; then
  error "Storage folder ($STORAGE) not found!" && exit 13
fi

if [ ! -w "$STORAGE" ]; then
  error "Storage folder ($STORAGE) is not writeable!" && exit 13
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

if [[ "${RAM_SIZE,,}" == "max" ]]; then
  RAM_WANTED=$(( RAM_AVAIL - RAM_SPARE - RAM_SPARE ))
  RAM_WANTED=$(( RAM_WANTED / 1073741825 ))
  RAM_SIZE="${RAM_WANTED}G"
fi

if [ -z "${RAM_SIZE//[0-9. ]}" ]; then
  [ "${RAM_SIZE%%.*}" -lt "130" ] && RAM_SIZE="${RAM_SIZE}G" || RAM_SIZE="${RAM_SIZE}M"
fi

RAM_SIZE=$(echo "${RAM_SIZE^^}" | sed 's/MB/M/g;s/GB/G/g;s/TB/T/g')
! numfmt --from=iec "$RAM_SIZE" &>/dev/null && error "Invalid RAM_SIZE: $RAM_SIZE" && exit 16
RAM_WANTED=$(numfmt --from=iec "$RAM_SIZE")
[ "$RAM_WANTED" -lt "136314880 " ] && error "RAM_SIZE is too low: $RAM_SIZE" && exit 16

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

# Check available memory

if [[ "$RAM_CHECK" != [Nn]* ]] && (( (RAM_WANTED + RAM_SPARE) > RAM_AVAIL )); then
  AVAIL_MEM=$(formatBytes "$RAM_AVAIL")
  msg="Your configured RAM_SIZE of ${RAM_SIZE/G/ GB} is too high for the $AVAIL_MEM of memory available, please set a lower value."
  [[ "${FS,,}" != "zfs" ]] && error "$msg" && exit 17
  info "$msg"
fi

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


: "${COM_PORT:="2210"}"    # Comm port
: "${MON_PORT:="7100"}"    # Monitor port
: "${WEB_PORT:="5000"}"    # Webserver port
: "${CHR_PORT:="12345"}"   # Character port

cp -r /var/www/* /run/shm
html "Starting $APP for $ENGINE..."

if [[ "${WEB:-}" != [Nn]* ]]; then

  mkdir -p /etc/nginx/sites-enabled
  cp /etc/nginx/default.conf /etc/nginx/sites-enabled/web.conf

  sed -i "s/listen 5000 default_server;/listen $WEB_PORT default_server;/g" /etc/nginx/sites-enabled/web.conf
  
  # shellcheck disable=SC2143
  if [ -f /proc/net/if_inet6 ] && [ -n "$(ifconfig -a | grep inet6)" ]; then

    sed -i "s/listen $WEB_PORT default_server;/listen [::]:$WEB_PORT default_server ipv6only=off;/g" /etc/nginx/sites-enabled/web.conf

  fi
  
  # Start webserver
  nginx -e stderr

fi

return 0
