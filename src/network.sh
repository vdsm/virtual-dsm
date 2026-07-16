#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables

: "${DHCP:="N"}"
: "${NETWORK:="Y"}"
: "${HOST_PORTS:=""}"
: "${USER_PORTS:=""}"
: "${ADAPTER:="virtio-net-pci"}"

: "${IP:="${VM_NET_IP:-}"}"
: "${DEV:="${VM_NET_DEV:-}"}"
: "${MTU:="${VM_NET_MTU:-}"}"
: "${TAP:="${VM_NET_TAP:-dsm}"}"
: "${HOST:="${VM_NET_HOST:-$APP}"}"
: "${MAC:="${VM_NET_MAC:-${MAC:-}}"}"
: "${BRIDGE:="${VM_NET_BRIDGE:-docker}"}"
: "${MASK:="${VM_NET_MASK:-255.255.255.0}"}"

: "${PASST:="/run/passt"}"
: "${PASST_OPTS:=""}"
: "${PASST_DEBUG:=""}"
: "${PASST_PID:="/var/run/passt.pid"}"
: "${PASST_SOCKET:="/tmp/passt.socket"}"

: "${DNSMASQ_OPTS:=""}"
: "${DNSMASQ_DEBUG:=""}"
: "${DNSMASQ:="/usr/sbin/dnsmasq"}"
: "${DNSMASQ_PID:="/var/run/dnsmasq.pid"}"

# Sanitize variables
IP=$(strip "$IP")
DEV=$(strip "$DEV")
MTU=$(strip "$MTU")
TAP=$(strip "$TAP")
MAC=$(strip "$MAC")
HOST=$(strip "$HOST")
MASK=$(strip "$MASK")
BRIDGE=$(strip "$BRIDGE")
ADAPTER=$(strip "$ADAPTER")
NETWORK=$(strip "$NETWORK")
HOST_PORTS=$(strip "$HOST_PORTS")
USER_PORTS=$(strip "$USER_PORTS")

ADD_ERR="Please add the following setting to your container:"

# ######################################
#  Generic helpers
# ######################################

isNAT() {

  case "${NETWORK,,}" in
    "nat" | "tap" | "tun" | "tuntap" | "y" | "" )
      return 0 ;;
    *)
      return 1 ;;
  esac
}

isUserMode() {

  case "${NETWORK,,}" in
    "passt" | "slirp" | "user"* )
      return 0 ;;
    *)
      return 1 ;;
  esac
}

getMTU() {

  local dev="$1"

  if [ -r "/sys/class/net/$dev/mtu" ]; then
    cat "/sys/class/net/$dev/mtu"
  else
    echo "0"
  fi

  return 0
}

minMTU() {

  local mtu=""
  local min=""

  for mtu in "$@"; do
    [[ -z "$mtu" || "$mtu" == "0" ]] && continue

    if [[ -z "$min" || "$mtu" -lt "$min" ]]; then
      min="$mtu"
    fi
  done

  echo "${min:-0}"
  return 0
}

setMTU() {

  local dev="$1"
  local mtu="$2"

  # MTU 0 means "do not set"; MTU 1500 is the normal default and does not need setting.
  [[ "$mtu" == "0" || "$mtu" == "1500" ]] && return 0

  if ! ip link set dev "$dev" mtu "$mtu"; then
    warn "failed to set MTU size of $dev to $mtu."
  fi

  return 0
}

gatewayMAC() {

  local mac="$1"

  echo "$mac" | md5sum | sed 's/^\(..\)\(..\)\(..\)\(..\)\(..\).*$/02:\1:\2:\3:\4:\5/'
}

maskToCIDR() {

  local mask="$1"
  local prefix=""

  if ! command -v ipcalc > /dev/null 2>&1; then
    error "Required command 'ipcalc' is not installed!"
    return 1
  fi

  prefix=$(ipcalc -n -b "0.0.0.0/$mask" 2>/dev/null | awk '
    /^Netmask:/ {
      for (i = 1; i <= NF; i++) {
        if ($i == "=") {
          print $(i + 1)
          exit
        }
      }
    }
  ')

  if [[ ! "$prefix" =~ ^[0-9]+$ ]] || (( prefix < 0 || prefix > 32 )); then
    error "Invalid MASK: '$mask'"
    return 1
  fi

  echo "$prefix"
  return 0
}

networkCIDR() {

  local ip="$1"
  local network=""

  network=$(ipcalc -n -b "$ip/$MASK" 2>/dev/null | awk '
    /^Network:/ {
      print $2
      exit
    }
  ')

  if [[ ! "$network" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+$ ]]; then
    error "Failed to calculate network address from IP '$ip' and netmask '$MASK'."
    return 1
  fi

  echo "$network"
  return 0
}

detectInterface() {

  if [ -n "$DEV" ]; then
    return 0
  fi

  # Prefer the last attached Kubernetes network
  [ -d "/sys/class/net/net0" ] && DEV="net0"
  [ -d "/sys/class/net/net1" ] && DEV="net1"
  [ -d "/sys/class/net/net2" ] && DEV="net2"
  [ -d "/sys/class/net/net3" ] && DEV="net3"

  # Automatically detect the default network interface
  [ -z "$DEV" ] && DEV=$(awk '$2 == 00000000 { print $1; exit }' /proc/net/route)
  [ -z "$DEV" ] && DEV="eth0"

  return 0
}

formatAddress() {

  local ip="${1:-}"
  local prefix="${2:-}"
  local result="$ip"

  [ -z "$result" ] && return 1

  if [ -n "$prefix" ] && [[ "$prefix" != "24" ]]; then
    result+="/$prefix"
  fi

  echo "$result"
  return 0
}

detectAddresses() {

  GATEWAY=$(ip route list dev "$DEV" | awk ' /^default/ {print $3}' | head -n 1)
  { UPLINK=$(ip address show dev "$DEV" | grep inet | awk '/inet / { print $2 }' | cut -f1 -d/ | head -n 1); } 2>/dev/null || :

  IP6=""

  if [ -f /proc/net/if_inet6 ] && [[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" != "1" ]]; then
    local rc=0
    { IP6=$(ip -6 addr show dev "$DEV" scope global up); rc=$?; } 2>/dev/null || :
    (( rc != 0 )) && IP6=""
    [ -n "$IP6" ] && IP6=$(echo "$IP6" | sed -e's/^.*inet6 \([^ ]*\)\/.*$/\1/;t;d' | head -n 1)
  fi

  return 0
}

detectAdapter() {

  local result=""

  NIC=""
  BUS=""

  result=$(ethtool -i "$DEV" 2>/dev/null || :)

  NIC=$(awk -F':[[:space:]]*' '
    tolower($1) == "driver" {
      print $2
      exit
    }
  ' <<< "$result")

  BUS=$(awk -F':[[:space:]]*' '
    tolower($1) == "bus-info" {
      print $2
      exit
    }
  ' <<< "$result")

  return 0
}

containerID() {

  local id=""

  id=$(hostname -s 2>/dev/null || true)

  if [ -z "$id" ] && [ -s /etc/machine-id ]; then
    id=$(< /etc/machine-id)
  fi

  if [ -z "$id" ] && [ -s /proc/sys/kernel/random/boot_id ]; then
    id=$(< /proc/sys/kernel/random/boot_id)
  fi

  [ -z "$id" ] && id="unknown"

  echo "$id"
  return 0
}

disableIPv6() {

  local dev="$1"

  [ -d "/proc/sys/net/ipv6/conf/$dev" ] || return 0

  # Best-effort only: Docker/rootless/container sysctl writes can fail.
  sysctl -w "net.ipv6.conf.$dev.disable_ipv6=1" > /dev/null 2>&1 || :
  sysctl -w "net.ipv6.conf.$dev.accept_ra=0" > /dev/null 2>&1 || :

  return 0
}

subnetInUse() {

  local subnet="$1"
  local broader="" narrower="" routes=""

  if ! broader=$(ip -4 route show table all match "$subnet" 2>/dev/null); then
    error "Failed to inspect existing routes for subnet $subnet."
    return 2
  fi

  if ! narrower=$(ip -4 route show table all root "$subnet" 2>/dev/null); then
    error "Failed to inspect existing routes for subnet $subnet."
    return 2
  fi

  routes=$(
    printf '%s\n%s\n' "$broader" "$narrower" |
      grep -Ev '(^|[[:space:]])default([[:space:]]|$)' |
      sort -u || true
  )

  [ -n "$routes" ]
}

guestIP() {

  local ip="$1"
  local min="${2:-2}"
  local last="${ip##*.}"

  if [[ ! "$last" =~ ^[0-9]+$ ]] || (( last < min || last > 254 )); then
    ip="${ip%.*}.$min"
  fi

  echo "$ip"
  return 0
}

natGuestIP() {

  local ip="$1"
  local start="" guest="" subnet=""
  local second="" third="" fourth="" rc=""

  third=$(cut -d. -f3 <<< "$ip")
  fourth=$(cut -d. -f4 <<< "$ip")

  if [[ "$ip" == "172.30."* ]]; then
    start="31"
  else
    start="30"
  fi

  guest=$(guestIP "172.$start.$third.$fourth" 2)
  fourth="${guest##*.}"

  for (( second=start; second<=254; second++ )); do
    guest="172.$second.$third.$fourth"
    subnet=$(networkCIDR "$guest") || return 1

    if subnetInUse "$subnet"; then
      continue
    else
      rc=$?
      (( rc == 1 )) || return 1
    fi

    echo "$guest"
    return 0
  done

  for (( second=30; second<start; second++ )); do
    guest="172.$second.$third.$fourth"
    subnet=$(networkCIDR "$guest") || return 1

    if subnetInUse "$subnet"; then
      continue
    else
      rc=$?
      (( rc == 1 )) || return 1
    fi

    echo "$guest"
    return 0
  done

  error "No available VM subnet found in 172.30.$third.0/$PREFIX through 172.254.$third.0/$PREFIX."
  return 1
}

kernelAtLeast() {

  local major="$1"
  local minor="${2:-0}"

  (( KERNEL > major || (KERNEL == major && MINOR >= minor) ))
}

canBindToDevice() {

  local dev="$1"
  [ -n "$dev" ] || return 1

  kernelAtLeast 5 7 || return 1
  [ -d "/sys/class/net/$dev" ] || return 1
  command -v python3 > /dev/null 2>&1 || return 0

  python3 - "$dev" > /dev/null 2>&1 <<'PY'
import socket
import sys

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.setsockopt(
        socket.SOL_SOCKET,
        socket.SO_BINDTODEVICE,
        sys.argv[1].encode() + b"\0",
    )
PY
}

# ######################################
#  DNS / port helpers
# ######################################

configureDNS() {

  local fa="$1"
  local ip="$2"
  local mac="$3"
  local host="$4"
  local mask="$5"
  local gateway="$6"
  local arguments="$DNSMASQ_OPTS" rc

  if ! echo "$gateway" > /run/shm/qemu.gw; then
    error "Failed to write gateway file."
    return 1
  fi

  enabled "${DNSMASQ_DISABLE:-}" && return 0
  enabled "$DEBUG" && echo "Starting dnsmasq daemon..."

  [ -s "$DNSMASQ_PID" ] && pKill "$(<"$DNSMASQ_PID")"
  rm -f "$DNSMASQ_PID"

  if isNAT; then

    # Create lease file for faster resolve
    echo "0 $mac $ip $host 01:$mac" > /var/lib/misc/dnsmasq.leases || :
    chmod 644 /var/lib/misc/dnsmasq.leases || :

    # dnsmasq configuration:
    arguments+=" --dhcp-authoritative"

    # Set DHCP range and host
    arguments+=" --dhcp-range=$ip,$ip"
    arguments+=" --dhcp-host=$mac,,$ip,$host,1h"

    # Set DNS server and gateway
    arguments+=" --dhcp-option=option:netmask,$mask"
    arguments+=" --dhcp-option=option:router,$gateway"
    arguments+=" --dhcp-option=option:dns-server,$gateway"

    # Set MTU through DHCP option 26
    if [[ "$GUEST_MTU" != "0" && "$GUEST_MTU" != "1500" ]]; then
      arguments+=" --dhcp-option=option:interface-mtu,$GUEST_MTU"
    fi

  fi

  # Set interfaces
  arguments+=" --interface=$fa"
  arguments+=" --bind-interfaces"

  # Workaround NET_RAW capability
  arguments+=" --no-ping"

  # Add DNS entry for container
  arguments+=" --address=/host.lan/$gateway"

  # Avoid returning IPv6 records when the active network mode is IPv4-only.
  if isNAT || [ -z "$IP6" ]; then
    arguments+=" --filter-AAAA"
  fi

  # Set local dns resolver to dnsmasq when needed
  [ -f /etc/resolv.dnsmasq ] && arguments+=" --resolv-file=/etc/resolv.dnsmasq"

  # Set pid file
  arguments+=" --pid-file=$DNSMASQ_PID"

  # Enable logging to file
  local log="/var/log/dnsmasq.log"
  rm -f "$log"
  arguments+=" --log-facility=$log"

  arguments=$(echo "$arguments" | sed 's/\t/ /g' | tr -s ' ' | sed 's/^ *//')
  enabled "$DEBUG" && printf "Dnsmasq arguments:\n\n%s\n\n" "${arguments// -/$'\n-'}"

  { $DNSMASQ ${arguments:+ $arguments}; rc=$?; } || :

  if (( rc != 0 )); then

    local msg="Failed to start Dnsmasq, reason: $rc"

    if [[ "${NETWORK,,}" == "slirp" || "${NETWORK,,}" == "passt" ]] || ! enabled "$ROOTLESS" || enabled "$DEBUG"; then
      [ -f "$log" ] && [ -s "$log" ] && cat "$log"
      error "$msg"
    fi

    return 1
  fi

  if enabled "$DNSMASQ_DEBUG"; then
    tail -fn +0 "$log" --pid=$$ &
  fi

  return 0
}

getHostPorts() {

  local port="" ports=""
  local num="" mode="${1:-tcp}"
  local list="${HOST_PORTS// /},"

  for port in ${list//,/ }; do

    [ -z "$port" ] && continue

    case "$mode" in
      "tcp" )
        [[ "$port" == *"/udp" ]] && continue
        num="${port%/tcp}"
        ;;
      "all" )
        if [[ "$port" == *"/udp" ]]; then
          num="${port%/udp}"
          [ -n "$num" ] && ports+="$num/udp,"
        else
          num="${port%/tcp}"
          [ -n "$num" ] && ports+="$num/tcp,"
        fi
        continue
        ;;
      *)
        return 1
        ;;
    esac

    [ -n "$num" ] && ports+="$num,"

  done

  # Remove duplicates
  ports=$(echo "${ports//,,/,}," | awk 'BEGIN{RS=ORS=","} !seen[$0]++' | sed 's/,*$//g')

  echo "$ports"
  return 0
}

getUserPorts() {

  local defaults="22/tcp,5000/tcp,5001/tcp"
  local list="$defaults,${USER_PORTS// /},"

  local num="" ports="" proto=""
  local userport="" hostport=""

  local exclude=""
  exclude=$(getHostPorts "all")

  for userport in ${list//,/ }; do

    proto="tcp"
    num="$userport"

    if [[ "$userport" == *"/udp" ]]; then
      proto="udp"
      num="${userport%/udp}"
    elif [[ "$userport" == *"/tcp" ]]; then
      proto="tcp"
      num="${userport%/tcp}"
    fi

    [ -z "$num" ] && continue

    for hostport in ${exclude//,/ }; do

      if [[ "$num/$proto" == "$hostport" ]]; then

        if [[ "$hostport" != "${WEB_PORT:-}/tcp" ]]; then
          warn "Could not assign port $hostport to \"USER_PORTS\" because it is already in \"HOST_PORTS\"!"
        fi

        num=""
        break
      fi

    done

    [ -n "$num" ] && ports+="$num/$proto,"

  done

  # Remove duplicates
  echo "${ports//,,/,}," | awk 'BEGIN{RS=ORS=","} !seen[$0]++' | sed 's/,*$//g'

  return 0
}

getSlirp() {

  local ip="$1"
  local args="" list=""

  list=$(getUserPorts)

  for port in ${list//,/ }; do

    local proto="tcp"
    local num="${port%/tcp}"
    [ -z "$num" ] && continue

    if [[ "$port" == *"/udp" ]]; then
      proto="udp"
      num="${port%/udp}"
    fi

    args+="hostfwd=$proto::$num-$ip:$num,"
  done

  echo "$args" | sed 's/,*$//g'
  return 0
}

getPasst() {

  local args="" list="" port=""
  local num="" tcp="" udp=""
  local bind="$UPLINK"

  list=$(getUserPorts)

  for port in ${list//,/ }; do

    [ -z "$port" ] && continue

    if [[ "$port" == *"/udp" ]]; then

      num="${port%/udp}"
      [ -n "$num" ] && udp+="$num,"

    elif [[ "$port" == *"/tcp" ]]; then

      num="${port%/tcp}"
      [ -n "$num" ] && tcp+="$num,"

    else

      tcp+="$port,"

    fi

  done

  tcp="${tcp%,}"
  udp="${udp%,}"

  if canBindToDevice "$DEV"; then
    bind="%$DEV"
  fi

  [ -n "$tcp" ] && args+=" -t $bind/$tcp"
  [ -n "$udp" ] && args+=" -u $bind/$udp"

  echo "$args"
  return 0
}

# ######################################
#  Network mode setup
# ######################################

configureVTAP() {

  local msg=""
  local rc

  enabled "$DEBUG" && echo "Configuring MACVTAP networking..."

  # Create the necessary file structure for /dev/vhost-net
  if [ ! -c /dev/vhost-net ]; then
    if mknod /dev/vhost-net c 10 238; then
      chmod 660 /dev/vhost-net
    fi
  fi

  # Create a macvtap network for the VM guest
  { msg=$(ip link add link "$DEV" name "$TAP" address "$MAC" type macvtap mode bridge 2>&1); rc=$?; } || :

  case "$msg" in
    "RTNETLINK answers: File exists"* )
      while ! ip link add link "$DEV" name "$TAP" address "$MAC" type macvtap mode bridge; do
        info "Waiting for macvtap interface to become available.."
        sleep 5
      done ;;
    "RTNETLINK answers: Invalid argument"* )
      error "Cannot create macvtap interface. Please make sure that the network type of the container is 'macvlan' and not 'ipvlan'."
      return 1 ;;
    "RTNETLINK answers: Operation not permitted"* )
      error "No permission to create macvtap interface. Please make sure that your host kernel supports it and that the NET_ADMIN capability is set."
      return 1 ;;
    *)
      [ -n "$msg" ] && echo "$msg" >&2
      if (( rc != 0 )); then
        error "Cannot create macvtap interface."
        return 1
      fi ;;
  esac

  if [[ "$GUEST_MTU" != "0" ]]; then
    setMTU "$TAP" "$GUEST_MTU"
    GUEST_MTU=$(minMTU "$GUEST_MTU" "$(getMTU "$TAP")")
  fi

  while ! ip link set "$TAP" up; do
    info "Waiting for MAC address $MAC to become available..."
    info "If you cloned this machine, please delete the 'dsm.mac' file to generate a different MAC address."
    sleep 2
  done

  local TAP_NR TAP_PATH MAJOR MINOR
  TAP_NR=$(</sys/class/net/"$TAP"/ifindex)
  TAP_PATH="/dev/tap${TAP_NR}"

  # Create dev file (there is no udev in container: need to be done manually)
  IFS=: read -r MAJOR MINOR < <(cat /sys/devices/virtual/net/"$TAP"/tap*/dev)
  (( MAJOR < 1)) && error "Cannot find: sys/devices/virtual/net/$TAP" && return 1

  [[ ! -e "$TAP_PATH" && -e "/dev0/${TAP_PATH##*/}" ]] && ln -s "/dev0/${TAP_PATH##*/}" "$TAP_PATH"

  if [[ ! -e "$TAP_PATH" ]]; then
    { mknod "$TAP_PATH" c "$MAJOR" "$MINOR"; rc=$?; } || :
    (( rc != 0 )) && error "Cannot mknod: $TAP_PATH ($rc)" && return 1
  fi

  { exec 30>>"$TAP_PATH"; rc=$?; } 2>/dev/null || :

  if (( rc != 0 )); then
    error "Cannot create TAP interface ($rc). $ADD_ERR --device-cgroup-rule='c *:* rwm'" && return 1
  fi

  { exec 40>>/dev/vhost-net; rc=$?; } 2>/dev/null || :

  if (( rc != 0 )); then
    error "VHOST can not be found ($rc). $ADD_ERR --device=/dev/vhost-net" && return 1
  fi

  NET_OPTS="-netdev tap,id=hostnet0,vhost=on,vhostfd=40,fd=30"

  return 0
}

configureSlirp() {

  NETWORK="slirp"
  enabled "$DEBUG" && echo "Configuring slirp networking..."

  local ip="$UPLINK"
  [ -n "$IP" ] && ip="$IP"

  ip=$(guestIP "$ip" 4)
  local gateway="${ip%.*}.1"
  local subnet=""
  subnet=$(networkCIDR "$ip") || return 1

  local ipv6="ipv6=off,"
  [ -n "$IP6" ] && ipv6="ipv6=on,"

  NET_OPTS="-netdev user,id=hostnet0,ipv4=on,host=$gateway,net=$subnet,dhcpstart=$ip,${ipv6}hostname=$HOST"

  local forward=""
  forward=$(getSlirp "$ip")
  [ -n "$forward" ] && NET_OPTS+=",$forward"

  if enabled "${DNSMASQ_DISABLE:-}"; then
    if ! echo "$gateway" > /run/shm/qemu.gw; then
      error "Failed to write gateway file."
      return 1
    fi
  else
    if [ ! -f /etc/resolv.dnsmasq ] && ! cp /etc/resolv.conf /etc/resolv.dnsmasq; then
      error "Failed to backup /etc/resolv.conf."
      return 1
    fi

    configureDNS "lo" "$ip" "$MAC" "$HOST" "$MASK" "$gateway" || return 1

    if ! printf '%s\n' \
      'nameserver 127.0.0.1' \
      'search .' \
      'options ndots:0' > /etc/resolv.conf; then
      error "Failed to update /etc/resolv.conf."
      return 1
    fi
  fi

  IP="$ip"
  return 0
}

configurePasst() {

  NETWORK="passt"
  enabled "$DEBUG" && echo "Configuring user-mode networking..."

  local log="/var/log/passt.log"
  rm -f "$log"

  local ip="$UPLINK"
  [ -n "$IP" ] && ip="$IP"

  ip=$(guestIP "$ip" 2)
  local gateway="${ip%.*}.1"

  # passt configuration:
  [ -z "$IP6" ] && PASST_OPTS+=" -4"

  PASST_OPTS+=" -a $ip"
  PASST_OPTS+=" -g $gateway"
  PASST_OPTS+=" -n $MASK"

  local passt_mtu="$GUEST_MTU"
  [[ "$passt_mtu" == "0" ]] && passt_mtu="1500"

  # Pass an explicit MTU to passt.
  PASST_OPTS+=" -m $passt_mtu"

  local forward=""
  forward=$(getPasst)
  [ -n "$forward" ] && PASST_OPTS+="$forward"

  PASST_OPTS+=" -H $HOST"
  PASST_OPTS+=" -M $GATEWAY_MAC"
  PASST_OPTS+=" -P $PASST_PID"
  PASST_OPTS+=" -s $PASST_SOCKET"
  PASST_OPTS+=" -l $log"
  PASST_OPTS+=" -q"

  if ! enabled "${DNSMASQ_DISABLE:-}"; then
    if [ ! -f /etc/resolv.dnsmasq ] && ! cp /etc/resolv.conf /etc/resolv.dnsmasq; then
      error "Failed to backup /etc/resolv.conf."
      return 1
    fi

    if ! printf '%s\n' \
      'nameserver 127.0.0.1' \
      'search .' \
      'options ndots:0' > /etc/resolv.conf; then
      error "Failed to update /etc/resolv.conf."
      return 1
    fi
  fi

  PASST_OPTS=$(echo "$PASST_OPTS" | sed 's/\t/ /g' | tr -s ' ' | sed 's/^ *//')

  if enabled "$DEBUG" || enabled "$PASST_DEBUG"; then
    printf "Passt arguments:\n\n%s\n\n" "${PASST_OPTS// -/$'\n-'}"
  fi

  [ ! -f "$PASST" ] && cp /usr/bin/passt* /run

  if ! "$PASST" ${PASST_OPTS:+$PASST_OPTS} >/dev/null 2>&1; then

    local rc=0
    rm -f "$log"

    PASST_OPTS="${PASST_OPTS/ -q/}"
    { "$PASST" ${PASST_OPTS:+$PASST_OPTS}; rc=$?; } || :

    if (( rc != 0 )); then
      [ -f "$log" ] && [ -s "$log" ] && cat "$log"
      warn "failed to start passt ($rc), falling back to slirp networking!"
      configureSlirp && return 0 || return 1
    fi

  fi

  if enabled "$PASST_DEBUG"; then
    tail -fn +0 "$log" --pid=$$ &
  elif enabled "$DEBUG"; then
    [ -f "$log" ] && [ -s "$log" ] && cat "$log" && echo ""
  fi

  NET_OPTS="-netdev stream,id=hostnet0,server=off,addr.type=unix,addr.path=$PASST_SOCKET"

  if ! configureDNS "lo" "$ip" "$MAC" "$HOST" "$MASK" "$gateway"; then
    mKill "$PASST_PID"
    rm -f "$PASST_PID" "$PASST_SOCKET"
    return 1
  fi

  IP="$ip"
  return 0
}

createBridge() {

  local gateway="$1"
  local rc msg=""

  # Create a bridge with a static IP for the VM guest
  { msg=$(ip link add dev "$BRIDGE" type bridge 2>&1); rc=$?; } || :

  if (( rc != 0 )); then
    enabled "$ROOTLESS" && ! enabled "$DEBUG" && return 1
    [ -n "$msg" ] && echo "$msg" >&2

    case "${msg,,}" in
      *"operation not permitted"* | *"permission denied"* )
        warn "failed to create bridge. $ADD_ERR --cap-add NET_ADMIN" ;;
      * )
        warn "failed to create bridge." ;;
    esac

    return 1
  fi

  if [[ "$GUEST_MTU" != "0" ]]; then
    setMTU "$BRIDGE" "$GUEST_MTU"
  fi

  if ! ip address add "$gateway/$PREFIX" dev "$BRIDGE"; then
    warn "failed to add IP address pool!" && return 1
  fi

  while ! ip link set "$BRIDGE" up; do
    info "Waiting for IP address to become available..."
    sleep 2
  done

  # NAT networking is IPv4-only; disable IPv6 on the guest bridge if possible.
  disableIPv6 "$BRIDGE"

  return 0
}

createTap() {

  local tuntap="$1"
  local rc msg=""

  # Set tap to the bridge created
  { msg=$(ip tuntap add dev "$TAP" mode tap 2>&1); rc=$?; } || :

  if (( rc != 0 )); then
    enabled "$ROOTLESS" && ! enabled "$DEBUG" && return 1
    [ -n "$msg" ] && echo "$msg" >&2
    warn "$tuntap"
    return 1
  fi

  if [[ "$GUEST_MTU" != "0" ]]; then
    setMTU "$TAP" "$GUEST_MTU"
  fi

  if ! ip link set dev "$TAP" address "$GATEWAY_MAC"; then
    warn "failed to set gateway MAC address."
  fi

  while ! ip link set "$TAP" up promisc on; do
    info "Waiting for TAP to become available..."
    sleep 2
  done

  # NAT networking is IPv4-only; disable IPv6 on the guest tap if possible.
  disableIPv6 "$TAP"

  if ! ip link set dev "$TAP" master "$BRIDGE"; then
    warn "failed to set master bridge!" && return 1
  fi

  return 0
}

# ######################################
#  IP tables
# ######################################

hasTable() {

  iptables -t "$1" -S > /dev/null 2>&1
}

getTablesBackend() {

  local version=""
  version=$(iptables --version 2>/dev/null || true)

  case "$version" in
    *nf_tables* ) echo "nft" ;;
    *legacy* ) echo "legacy" ;;
    * ) return 1 ;;
  esac
}

setTables() {

  local mode="$1"
  local path=""

  path=$(command -v "iptables-$mode" 2>/dev/null || true)
  [ -z "$path" ] && return 1

  update-alternatives --set iptables "$path" > /dev/null 2>&1
}

showRules() {

  local table="$1"
  local chain="$2"
  local label="$3"
  local rule_tag="$4"
  local rules=""
  local own_rule="--comment[[:space:]]+\"?$rule_tag\"?([[:space:]]|\$)"

  enabled "$DEBUG" || return 0

  rules=$(
    iptables -t "$table" -S "$chain" 2>/dev/null |
      awk '$1 == "-A"' |
      grep -Ev -- "$own_rule" || true
  )

  [ -n "$rules" ] || return 0

  printf "Existing %s rules:\n\n%s\n\n" "$label" "$rules"
  return 0
}

checkExistingTables() {

  local msg="" rules="" conflicts=""
  local rule_tag="QEMU_DNAT"
  local own_rule="--comment[[:space:]]+\"?$rule_tag\"?([[:space:]]|\$)"

  rules=$(
    iptables -t nat -S PREROUTING 2>/dev/null |
      awk '$1 == "-A"' |
      grep -Ev -- "$own_rule" || true
  )

  conflicts=$(grep -E -- \
    '^-A PREROUTING .*(-j DNAT|-j REDIRECT)( |$)' \
    <<< "$rules" || true)

  if [ -n "$conflicts" ]; then
    msg="your existing NAT rules may take precedence over VM port forwarding"

    if enabled "$DEBUG"; then
      warn "${msg}."
    else
      warn "${msg}; enable DEBUG=Y to inspect them."
    fi
  fi

  rules=$(
    iptables -t filter -S FORWARD 2>/dev/null |
      awk '$1 == "-A"' |
      grep -Ev -- "$own_rule" || true
  )

  conflicts=$(grep -E -- \
    '^-A FORWARD .*(-j DROP|-j REJECT)( |$)' \
    <<< "$rules" || true)

  if [ -n "$conflicts" ]; then
    msg="your existing firewall rules may block traffic forwarded to or from the VM"

    if enabled "$DEBUG"; then
      warn "${msg}."
    else
      warn "${msg}; enable DEBUG=Y to inspect them."
    fi
  fi

  showRules nat PREROUTING "NAT PREROUTING" "$rule_tag"
  showRules filter FORWARD "filter FORWARD" "$rule_tag"
  showRules nat POSTROUTING "NAT POSTROUTING" "$rule_tag"

  if hasTable mangle; then
    showRules mangle FORWARD "mangle FORWARD" "$rule_tag"
    showRules mangle POSTROUTING "mangle POSTROUTING" "$rule_tag"
  else
    warn "the mangle iptable is unavailable, so checksum correction and TCP MSS clamping rules will be skipped."
  fi

  return 0
}

runTableRule() {

  local silent="$1"
  local result="$2"
  local rc msg=""

  shift 2

  printf -v "$result" '%s' ""

  { msg=$("$@" 2>&1); rc=$?; } || :
  (( rc == 0 )) && return 0

  printf -v "$result" '%s' "$msg"

  if ! enabled "$silent" || enabled "$DEBUG"; then
    [ -n "$msg" ] && echo "$msg" >&2
  fi

  return 1
}

tableError() {

  local silent="$1"
  local message="${2,,}"

  if enabled "$silent" && ! enabled "$DEBUG"; then
    return 1
  fi

  case "$message" in
    *"permission denied"* | *"operation not permitted"* )
      warn "IP tables access was denied. Add the NET_ADMIN capability or use user-mode networking."
      ;;
    *"table does not exist"* | *"can't initialize iptables table"* )
      warn "The required IP tables kernel modules may be unavailable. Try: sudo modprobe ip_tables iptable_nat"
      ;;
    *"no chain/target/match by that name"* )
      warn "A required IP tables target or match is unavailable in the host kernel."
      ;;
    *"could not fetch rule set generation id"* )
      warn "The nftables backend is unavailable or inaccessible in this container."
      ;;
    * )
      warn "Failed to configure IP tables. Verify NET_ADMIN access and host IP tables support."
      ;;
  esac

  return 1
}

applyTables() {

  local ip="$1"
  local subnet="$2"
  local silent="${3:-N}"
  local exclude="" port=""
  local table_error=""
  local dnat_chain="QEMU_DNAT"
  local rule_tag="$dnat_chain"

  exclude=$(getHostPorts)

  # NAT traffic from the VM subnet leaving through any external interface.
  if ! runTableRule "$silent" table_error \
    iptables -t nat -A POSTROUTING \
    ! -o "$BRIDGE" \
    -s "$subnet" \
    ! -d "$subnet" \
    -m comment --comment "$rule_tag" \
    -j MASQUERADE; then
    tableError "$silent" "$table_error"
    return 1
  fi

  # Use a dedicated chain so protected TCP ports do not depend on multiport support.
  if ! runTableRule "$silent" table_error \
    iptables -t nat -N "$dnat_chain"; then
    tableError "$silent" "$table_error"
    return 1
  fi

  # Keep container-owned TCP ports handled by the container.
  for port in ${exclude//,/ }; do

    [ -z "$port" ] && continue

    if ! runTableRule "$silent" table_error \
      iptables -t nat -A "$dnat_chain" \
      -p tcp \
      --dport "$port" \
      -m comment --comment "$rule_tag" \
      -j RETURN; then
      tableError "$silent" "$table_error"
      return 1
    fi

  done

  # Forward every remaining protocol and port to the VM.
  if ! runTableRule "$silent" table_error \
    iptables -t nat -A "$dnat_chain" \
    -m comment --comment "$rule_tag" \
    -j DNAT --to "$ip"; then
    tableError "$silent" "$table_error"
    return 1
  fi

  # Process incoming traffic addressed to the container through the VM chain.
  if ! runTableRule "$silent" table_error \
    iptables -t nat -A PREROUTING \
    ! -i "$BRIDGE" \
    -m addrtype --dst-type LOCAL \
    -m comment --comment "$rule_tag" \
    -j "$dnat_chain"; then
    tableError "$silent" "$table_error"
    return 1
  fi

  # Hack for guest VMs complaining about "bad udp checksums in 5 packets".
  runTableRule "Y" table_error \
    iptables -t mangle -A POSTROUTING \
    -s "$subnet" \
    -p udp \
    --dport bootpc \
    -m comment --comment "$rule_tag" \
    -j CHECKSUM --checksum-fill || true

  # Clamp TCP MSS to avoid subtle MTU blackholes when the outer path has a smaller MTU.
  runTableRule "Y" table_error \
    iptables -t mangle -A FORWARD \
    -s "$subnet" \
    -p tcp \
    --tcp-flags SYN,RST SYN \
    -m comment --comment "$rule_tag" \
    -j TCPMSS --clamp-mss-to-pmtu || true

  runTableRule "Y" table_error \
    iptables -t mangle -A FORWARD \
    -d "$ip" \
    -p tcp \
    --tcp-flags SYN,RST SYN \
    -m comment --comment "$rule_tag" \
    -j TCPMSS --clamp-mss-to-pmtu || true

  # Allow forwarding from the VM bridge to external interfaces.
  if ! runTableRule "$silent" table_error \
    iptables -A FORWARD \
    -i "$BRIDGE" \
    ! -o "$BRIDGE" \
    -s "$subnet" \
    -m comment --comment "$rule_tag" \
    -j ACCEPT; then
    tableError "$silent" "$table_error"
    return 1
  fi

  # Allow forwarding from external interfaces to the VM.
  if ! runTableRule "$silent" table_error \
    iptables -A FORWARD \
    ! -i "$BRIDGE" \
    -o "$BRIDGE" \
    -d "$ip" \
    -m comment --comment "$rule_tag" \
    -j ACCEPT; then
    tableError "$silent" "$table_error"
    return 1
  fi

  return 0
}

clearTables() {

  local table="" line=""
  local rules="" failed="N"
  local dnat_chain="QEMU_DNAT"
  local rule_tag="$dnat_chain"
  local re="--comment[[:space:]]+\"?$rule_tag\"?([[:space:]]|\$)"

  # Return 2 when the currently selected backend cannot be accessed.
  # This lets configureTables() distinguish it from an actual rule-cleanup failure.
  if ! rules=$(iptables-save 2> /dev/null); then
    return 2
  fi

  if [ -n "$rules" ]; then

    # Delete every rule tagged with our unique identifier,
    # leaving all other rules intact.
    while IFS= read -r line; do

      case "$line" in
        \*nat ) table="nat" ;;
        \*filter ) table="filter" ;;
        \*mangle ) table="mangle" ;;
        \*raw ) table="raw" ;;
      esac

      if [[ "$line" == -A* ]] && [[ "$line" =~ $re ]]; then
        line="${line/-A /-D }"

        # Parse the quoting produced by iptables-save before deleting the rule.
        if ! printf '%s\n' "$line" |
          xargs -r iptables -t "$table" > /dev/null 2>&1; then
          failed="Y"
        fi
      fi

    done <<< "$rules"

  fi

  # Remove the dedicated DNAT chain after deleting its rules and references.
  if iptables -t nat -S "$dnat_chain" > /dev/null 2>&1; then

    if ! iptables -t nat -F "$dnat_chain" > /dev/null 2>&1; then
      failed="Y"
    fi

    if ! iptables -t nat -X "$dnat_chain" > /dev/null 2>&1; then
      failed="Y"
    fi

  fi

  enabled "$failed" && return 1
  return 0
}

configureTables() {

  local ip="$1"
  local subnet="$2"
  local preferred=""
  local alternate="" rc=0
  local preferred_clean="N"
  local alternate_dirty="N"

  preferred=$(getTablesBackend) || {
    enabled "$ROOTLESS" && ! enabled "$DEBUG" && return 1
    warn "failed to determine the active IP tables backend!"
    return 1
  }

  case "$preferred" in
    "nft" ) alternate="legacy" ;;
    "legacy" ) alternate="nft" ;;
    * )
      enabled "$ROOTLESS" && ! enabled "$DEBUG" && return 1
      warn "unsupported IP tables backend: $preferred"
      return 1 ;;
  esac

  # Try the preferred backend first.
  if clearTables; then

    preferred_clean="Y"

    # Try the preferred backend without reporting provisional failures.
    if applyTables "$ip" "$subnet" "Y"; then
      checkExistingTables
      return 0
    fi

    # Never switch backends while partial rules remain in the preferred backend.
    if ! clearTables; then
      enabled "$ROOTLESS" && ! enabled "$DEBUG" && return 1
      warn "failed to clean up the partial $preferred IP tables configuration!"
      return 1
    fi

  else

    rc=$?

    # The preferred backend was accessible, but its rules could not be removed.
    # Do not switch while partial or stale rules may still be active.
    if (( rc == 1 )); then
      enabled "$ROOTLESS" && ! enabled "$DEBUG" && return 1
      warn "failed to clean up the existing $preferred IP tables configuration!"
      return 1
    fi

    # Return code 2 means the preferred backend itself could not be accessed,
    # so it is safe to try the alternate backend.
    if (( rc != 2 )); then
      enabled "$ROOTLESS" && ! enabled "$DEBUG" && return 1
      warn "failed to access the $preferred IP tables backend!"
      return 1
    fi

    if enabled "$DEBUG"; then
      warn "failed to access the $preferred IP tables backend!"
    fi

  fi

  # Try the alternate backend when the preferred backend failed.
  if setTables "$alternate"; then

    # Remove rules left by a previous run from the alternate backend.
    if clearTables; then

      if applyTables "$ip" "$subnet" "Y"; then
        checkExistingTables
        return 0
      fi

      if ! clearTables; then

        alternate_dirty="Y"

        if ! enabled "$ROOTLESS" || enabled "$DEBUG"; then
          warn "failed to clean up the partial $alternate IP tables configuration!"
        fi

      fi

    else

      rc=$?

      # Only mark the alternate backend dirty when it was accessible but cleanup failed.
      if (( rc == 1 )); then

        alternate_dirty="Y"

        if ! enabled "$ROOTLESS" || enabled "$DEBUG"; then
          warn "failed to clean up the existing $alternate IP tables configuration!"
        fi

      elif (( rc != 2 )); then

        alternate_dirty="Y"

        if ! enabled "$ROOTLESS" || enabled "$DEBUG"; then
          warn "failed to inspect the existing $alternate IP tables configuration!"
        fi

      elif enabled "$DEBUG"; then
        warn "failed to access the $alternate IP tables backend!"
      fi

    fi
  fi

  # Restore the preferred backend after the alternate attempt failed.
  if ! setTables "$preferred"; then
    enabled "$ROOTLESS" && ! enabled "$DEBUG" && return 1
    warn "failed to restore the preferred $preferred IP tables backend!"
    return 1
  fi

  # Do not continue while partial rules remain in the alternate backend.
  enabled "$alternate_dirty" && return 1

  # Both backend failures were already shown in debug mode.
  enabled "$DEBUG" && return 1

  # Rootless NAT failures should remain silent before falling back.
  enabled "$ROOTLESS" && return 1

  # An inaccessible preferred backend cannot be retried diagnostically.
  if ! enabled "$preferred_clean"; then
    warn "failed to access both IP tables backends!"
    return 1
  fi

  # Verify that no rules remain before the diagnostic attempt.
  if ! clearTables; then
    warn "failed to clean up the existing $preferred IP tables configuration!"
    return 1
  fi

  # Repeat the preferred backend once to show its actual failure.
  if applyTables "$ip" "$subnet" "N"; then
    checkExistingTables
    return 0
  fi

  # Do not leave a partial ruleset after the final failed attempt.
  if ! clearTables; then
    warn "failed to clean up the partial $preferred IP tables configuration!"
  fi

  return 1
}

configureNAT() {

  local tuntap="TUN device is missing. $ADD_ERR --device /dev/net/tun"
  local rc ip subnet msg="" forwarding=""

  enabled "$DEBUG" && echo "Configuring NAT networking..."

  # Create the necessary file structure for /dev/net/tun
  if [ ! -c /dev/net/tun ]; then
    [ ! -d /dev/net ] && mkdir -m 755 /dev/net > /dev/null 2>&1 || :

    { msg=$(mknod /dev/net/tun c 10 200 2>&1); rc=$?; } || :

    if (( rc == 0 )); then
      chmod 666 /dev/net/tun
    elif ! enabled "$ROOTLESS" || enabled "$DEBUG"; then
      [ -n "$msg" ] && echo "$msg" >&2
    fi
  fi

  if [ ! -c /dev/net/tun ]; then
    enabled "$ROOTLESS" && ! enabled "$DEBUG" && return 1
    warn "$tuntap" && return 1
  fi

  # Check port forwarding flag
  [ -r /proc/sys/net/ipv4/ip_forward ] &&
    forwarding=$(< /proc/sys/net/ipv4/ip_forward)

  if [[ "$forwarding" != "1" ]]; then
    { sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1; rc=$?; } || :

    forwarding=""
    [ -r /proc/sys/net/ipv4/ip_forward ] &&
      forwarding=$(< /proc/sys/net/ipv4/ip_forward)

    if (( rc != 0 )) || [[ "$forwarding" != "1" ]]; then
      enabled "$ROOTLESS" && ! enabled "$DEBUG" && return 1
      warn "IP forwarding is disabled. $ADD_ERR --sysctl net.ipv4.ip_forward=1"
      return 1
    fi
  fi

  if [ -n "$IP" ]; then
    ip=$(guestIP "$IP" 2)
  else
    ip=$(natGuestIP "$UPLINK") || return 1
  fi

  local gateway="${ip%.*}.1"
  subnet=$(networkCIDR "$ip") || return 1

  if subnetInUse "$subnet"; then
    error "VM subnet $subnet conflicts with an existing route inside the container."
    return 1
  else
    rc=$?
    (( rc == 1 )) || return 1
  fi

  createBridge "$gateway" || return 1
  createTap "$tuntap" || return 1

  # Use the lowest effective guest-facing MTU, without mutating the parent/uplink MTU.
  if [[ "$GUEST_MTU" != "0" ]]; then
    GUEST_MTU=$(minMTU "$GUEST_MTU" "$(getMTU "$BRIDGE")" "$(getMTU "$TAP")")
  fi

  configureTables "$ip" "$subnet" || return 1

  NET_OPTS="-netdev tap,id=hostnet0,ifname=$TAP"

  if [ -c /dev/vhost-net ]; then
    { exec 40>>/dev/vhost-net; rc=$?; } 2>/dev/null || :
    (( rc == 0 )) && NET_OPTS+=",vhost=on,vhostfd=40"
  fi

  NET_OPTS+=",script=no,downscript=no"

  configureDNS "$BRIDGE" "$ip" "$MAC" "$HOST" "$MASK" "$gateway" || return 1

  IP="$ip"
  return 0
}

# ######################################
#  Cleanup
# ######################################

closeInterfaces() {

  local pids=( "$PASST_PID" "$DNSMASQ_PID" )
  mKill "${pids[@]}"

  exec 30>&- 2>/dev/null || true
  exec 40>&- 2>/dev/null || true

  ip link set "$TAP" down promisc off &> /dev/null || :
  ip link delete "$TAP" &> /dev/null || :

  ip link set "$BRIDGE" down &> /dev/null || :
  ip link delete "$BRIDGE" &> /dev/null || :

  clearTables || :
  return 0
}

closeWeb() {

  local pids=( "${WEB_PID:-}" "${WSD_PID:-}" )
  mKill "${pids[@]}"

  return 0
}

closeNetwork() {

  if ! disabled "${WEB:-}" && enabled "$DHCP"; then
    closeWeb
  fi

  disabled "$NETWORK" && return 0

  closeInterfaces

  return 0
}

# ######################################
#  Detection
# ######################################

checkOS() {

  local iface="macvlan"
  local os="" kernel=""

  kernel=$(uname -a)

  [[ "${kernel,,}" == *"darwin"* ]] && os="$ENGINE Desktop for macOS"
  [[ "${kernel,,}" == *"microsoft"* ]] && os="$ENGINE Desktop for Windows"

  if enabled "$DHCP"; then
    iface="macvtap"
    [[ "${kernel,,}" == *"synology"* ]] && os="Synology Container Manager"
  fi

  if [ -n "$os" ]; then
    warn "you are using $os which does not support $iface, please revert to bridge networking!"
  fi

  return 0
}

validateInterface() {

  if [ ! -d "/sys/class/net/$DEV" ]; then
    error "Network interface '$DEV' does not exist inside the container!"
    error "$ADD_ERR -e \"DEV=NAME\" to specify another interface name."
    exit 26
  fi

  return 0
}

validateMask() {

  PREFIX=$(maskToCIDR "$MASK") || exit 28

  if ! enabled "$DHCP" && (( PREFIX < 16 || PREFIX > 24 )); then
    error "Unsupported MASK: '$MASK' (supported range: /16 through /24)"
    exit 28
  fi

  return 0
}

validateHost() {

  HOST="${HOST//[^A-Za-z0-9-]/-}"
  HOST=$(echo "$HOST" | sed 's/^-*//;s/-*$//;s/--*/-/g')

  if [ -z "$HOST" ]; then
    HOST="$APP"
    HOST="${HOST//[^A-Za-z0-9-]/-}"
    HOST=$(echo "$HOST" | sed 's/^-*//;s/-*$//;s/--*/-/g')
  fi

  return 0
}

validateHostPorts() {

  if isNAT && [[ "${HOST_PORTS,,}" == *"/udp"* ]]; then
    warn "UDP ports in \"HOST_PORTS\" are not yet implemented for NAT networking."
  fi

  return 0
}

validateAddresses() {

  # DHCP/macvtap mode can work without a detectable container IPv4 address,
  # because the guest receives its address directly from the external LAN.
  if [ -z "$UPLINK" ] && ! enabled "$DHCP"; then
    error "Could not determine container IPv4 address!"
    exit 26
  fi

  return 0
}

validateAdapter() {

  if [[ -n "$BUS" && "${BUS,,}" != "n/a" && "${BUS,,}" != "tap" ]]; then
    enabled "$DEBUG" && info "Detected NIC: ${NIC:-unknown}  BUS: $BUS"
    error "This container does not support host mode networking!"
    exit 29
  fi

  if enabled "$DHCP"; then

    checkOS

    if [[ "${NIC,,}" == "ipvlan" ]]; then
      error "This container does not support IPVLAN networking when DHCP=Y."
      exit 29
    fi

    if [[ "${NIC,,}" != "macvlan" ]]; then
      enabled "$DEBUG" && info "Detected NIC: ${NIC:-unknown}"
      error "The container needs to be in a MACVLAN network when DHCP=Y."
      exit 29
    fi

    if uname -a | grep -Eqi 'unraid|truenas'; then

      # Check if host exposes the bridge-nf sysctl
      # (only visible if br_netfilter is loaded and /proc/sys is accessible)

      local bnf="/proc/sys/net/bridge/bridge-nf-call-iptables"

      if [[ -r "$bnf" ]] && [[ "$(<"$bnf")" != "0" ]]; then
        warn "external LAN clients may not be able to reach this container, because net.bridge.bridge-nf-call-iptables=1."
        warn "you can fix this issue by running 'sysctl -w net.bridge.bridge-nf-call-iptables=0' on the host system."
      fi

    fi

  else

    if [[ "$UPLINK" != "172."* && "$UPLINK" != "10.8"* && "$UPLINK" != "10.9"* ]]; then
      checkOS
    fi

  fi

  return 0
}

configureMTU() {

  local mtu=""
  local mtu_custom="N"

  if [ -f "/sys/class/net/$DEV/mtu" ]; then
    mtu=$(< "/sys/class/net/$DEV/mtu")
  fi

  [ -n "$MTU" ] && mtu_custom="Y"
  [ -z "$MTU" ] && MTU="$mtu"
  [ -z "$MTU" ] && MTU="0"

  GUEST_MTU="$MTU"

  # Automatically propagate smaller-than-standard MTUs, but do not automatically
  # advertise jumbo frames unless the user explicitly requested MTU.
  if [[ "$GUEST_MTU" != "0" && "$GUEST_MTU" -gt "1500" ]] && ! enabled "$mtu_custom"; then
    GUEST_MTU="1500"
  fi

  return 0
}

configureMAC() {

  local container=""
  local file=""

  container=$(containerID)

  if [ -z "$MAC" ]; then

    file="$STORAGE/dsm.mac"

    if [ -s "$file" ]; then
      if ! MAC=$(readFile "$file"); then
        error "Failed to read MAC address from \"$file\" !"
        exit 28
      fi
    fi

    if [ -z "$MAC" ]; then

      # Generate a Synology-style MAC address based on a stable container identifier when possible.
      MAC=$(echo "$container" | md5sum | sed 's/^\(..\)\(..\)\(..\)\(..\)\(..\).*$/02:11:32:\3:\4:\5/')

      if ! writeFile "${MAC^^}" "$file"; then
        error "Failed to write MAC address to \"$file\" !"
        exit 28
      fi

    fi
  fi

  MAC="${MAC^^}"
  MAC="${MAC//-/:}"

  if [[ ${#MAC} == 12 ]]; then
    local m="$MAC"
    MAC="${m:0:2}:${m:2:2}:${m:4:2}:${m:6:2}:${m:8:2}:${m:10:2}"
  fi

  if [[ ${#MAC} != 17 ]]; then
    error "Invalid MAC address: '$MAC', should be 12 or 17 digits long!"
    exit 28
  fi

  # Keep the guest-facing gateway MAC stable across runs.
  GATEWAY_MAC=$(gatewayMAC "$MAC")

  return 0
}

showHostInfo() {

  local mtu="" host="" uplink="" prefix=""

  prefix=$(ip -4 -o address show dev "$DEV" scope global 2>/dev/null |
    awk -v ip="$UPLINK" '
      {
        split($4, address, "/")
        if (address[1] == ip) {
          print address[2]
          exit
        }
      }
    ')

  uplink=$(formatAddress "$UPLINK" "$prefix" || true)
  [ -z "$uplink" ] && uplink="(none)"

  local line="❯ Host: $uplink"

  host=$(containerID)
  [ -n "$host" ] && line+=" ($host)"

  local obvious=""
  if [[ "$UPLINK" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.[0-9]+$ ]]; then
    obvious="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}.1"
  fi

  local gateway="${GATEWAY:-}"
  if [ -z "$gateway" ]; then
    line+="  |  Gateway: (none)"
  elif [[ "$gateway" != "$obvious" ]]; then
    line+="  |  Gateway: $gateway"
  fi

  local iface="$DEV"
  if [ -n "$NIC" ] && [[ "${NIC,,}" != "veth" ]]; then
    iface+="/$NIC"
  fi

  [ -z "$iface" ] && iface="(none)"
  [[ "$iface" != "eth0" ]] && line+="  |  Interface: $iface"

  mtu=$(getMTU "$DEV")
  if [ -n "$mtu" ] && [[ "$mtu" != "0" && "$mtu" != "1500" ]]; then
    line+="  |  MTU: $mtu"
  fi

  local nameservers=""
  local file="/etc/resolv.dnsmasq"
  [ ! -f "$file" ] && file="/etc/resolv.conf"

  if [ -f "$file" ]; then
    nameservers=$(grep '^nameserver ' "$file" | sed 's/^nameserver //' | paste -sd ',' | sed 's/,/, /g')
  fi

  [ -z "$nameservers" ] && nameservers="(none)"
  [[ "$nameservers" == "127.0.0.1"* ]] && nameservers=""

  echo

  if (( ${#nameservers} <= 40 )); then
    [ -n "$nameservers" ] && line+="  |  DNS: $nameservers"
    echo "$line"
  else
    echo "$line"
    echo "❯ DNS: $nameservers"
  fi

  return 0
}

showGuestInfo() {

  local ip="${IP:-}"

  [ -n "$ip" ] && ip=$(formatAddress "$ip" "$PREFIX" || true)
  [ -z "$ip" ] && ip="DHCP"

  local line="❯ Guest: $ip"

  if [ -n "${HOST:-}" ]; then
    line+=" ($HOST)"
  fi

  local mode="${NETWORK,,}"

  if isNAT; then
    mode="NAT"
  elif enabled "$DHCP"; then
    mode="DHCP"
  elif isUserMode; then
    mode="User ($mode)"
  elif [ -z "$mode" ]; then
    mode="(none)"
  fi

  line+="  |  Mode: $mode"

  [ -n "$MAC" ] && line+="  |  MAC: $MAC"

  echo "$line"
  echo
  return 0
}

initializeNetwork() {

  detectInterface
  validateInterface

  validateMask
  validateHost
  validateHostPorts

  detectAddresses
  validateAddresses

  detectAdapter
  validateAdapter

  configureMTU
  configureMAC

  showHostInfo

  if [[ "$UPLINK" == "172.17."* ]]; then
    warn "your container IP starts with 172.17.* which will cause conflicts when you install the Container Manager package inside DSM!"
  fi

  closeInterfaces

  # Clean up old files
  rm -f "$PASST_PID" "$PASST_SOCKET"
  rm -f "$DNSMASQ_PID" /etc/resolv.dnsmasq

  return 0
}

# ######################################
#  Configure Network
# ######################################

if disabled "$NETWORK"; then
  NET_OPTS=""
  return 0
fi

msg="Initializing network..."
html "$msg"
enabled "$DEBUG" && echo "$msg"

initializeNetwork

MSG="Booting DSM instance..."
html "$MSG"

if enabled "$DHCP"; then

  # Configure for macvtap interface
  configureVTAP || exit 20
  showGuestInfo

else

  if ! disabled "${WEB:-}"; then
    sleep 1.2
    closeWeb
  fi

  if isNAT; then

    # Configure tap interface
    if ! configureNAT; then

      closeInterfaces
      NETWORK="user"

      if ! enabled "$ROOTLESS" || enabled "$DEBUG"; then
        msg="falling back to user-mode networking!"
        msg="failed to setup NAT networking, $msg"
        warn "$msg"
      fi

    fi

  fi

  if isUserMode; then

    case "${NETWORK,,}" in
      "passt" | "user"* )

        # Configure for user-mode networking (passt)
        if ! configurePasst; then
          error "Failed to configure user-mode networking!"
          exit 24
        fi ;;

      "slirp" )

        # Configure for user-mode networking (slirp)
        if ! configureSlirp; then
          error "Failed to configure user-mode networking!"
          exit 24
        fi ;;

    esac

  elif ! isNAT; then

    error "Unrecognized NETWORK value: \"$NETWORK\"" && exit 24

  fi

  showGuestInfo

  if isUserMode && [ -z "$USER_PORTS" ]; then
    info "Notice: because user-mode networking is active, when you need to forward custom ports to DSM, add them to the \"USER_PORTS\" variable."
  fi

fi

NET_OPTS+=" -device $ADAPTER,id=net0,netdev=hostnet0,romfile=,mac=$MAC"

if [[ "$GUEST_MTU" != "0" && "$GUEST_MTU" != "1500" ]]; then
  if [[ "${ADAPTER,,}" == "virtio-net-pci" ]]; then
    NET_OPTS+=",host_mtu=$GUEST_MTU"
  elif [[ "$GUEST_MTU" -lt "1500" ]]; then
    warn "MTU size is $GUEST_MTU, but cannot be advertised for $ADAPTER adapters; networking may break on paths below 1500 MTU."
  fi
fi

if ! echo "$UPLINK" > "$QEMU_DIR"/qemu.ip; then
  error "Failed to write QEMU IP file!"
  exit 24
fi

if ! echo "$NIC" > "$QEMU_DIR"/qemu.nic; then
  error "Failed to write QEMU NIC file!"
  exit 24
fi

return 0
