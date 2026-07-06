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
: "${MAC:="${VM_NET_MAC:-${MAC:-}}"}"
: "${HOST:="${VM_NET_HOST:-VirtualDSM}"}"
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
    "tap" | "tun" | "tuntap" | "y" | "" )
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

  if [[ "$ip" != "172.30."* ]]; then
    ip="172.30.$(cut -d. -f3,4 <<< "$ip")"
  else
    ip="172.31.$(cut -d. -f3,4 <<< "$ip")"
  fi

  guestIP "$ip" 2
}

maskToCIDR() {

  local mask="$1"
  local prefix=""

  prefix=$(ipcalc -p 0.0.0.0 "$mask" | awk -F= '/^PREFIX=/ { print $2 }')

  if [[ ! "$prefix" =~ ^[0-9]+$ ]] || (( prefix < 1 || prefix > 30 )); then
    error "Invalid MASK: '$mask'"
    return 1
  fi

  echo "$prefix"
  return 0
}

networkCIDR() {

  local ip="$1"
  local network=""

  network=$(ipcalc -n "$ip" "$MASK" | awk -F= '/^NETWORK=/ { print $2 }')

  if [ -z "$network" ]; then
    error "Failed to calculate network address from IP '$ip' and netmask '$MASK'."
    return 1
  fi

  echo "$network/$PREFIX"
  return 0
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

detectInterface() {

  if [ -n "$DEV" ]; then
    return 0
  fi

  # Give Kubernetes priority over the default interface
  [ -d "/sys/class/net/net0" ] && DEV="net0"
  [ -d "/sys/class/net/net1" ] && DEV="net1"
  [ -d "/sys/class/net/net2" ] && DEV="net2"
  [ -d "/sys/class/net/net3" ] && DEV="net3"

  # Automatically detect the default network interface
  [ -z "$DEV" ] && DEV=$(awk '$2 == 00000000 { print $1; exit }' /proc/net/route)
  [ -z "$DEV" ] && DEV="eth0"

  return 0
}

detectAddresses() {

  GATEWAY=$(ip route list dev "$DEV" | awk ' /^default/ {print $3}' | head -n 1)
  { UPLINK=$(ip address show dev "$DEV" | grep inet | awk '/inet / { print $2 }' | cut -f1 -d/ | head -n 1); } 2>/dev/null || :

  IP6=""

  if [ -f /proc/net/if_inet6 ] && [[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" != "1" ]]; then
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

  NIC=$(grep -m 1 -i 'driver:' <<< "$result" | awk '{print $2}')
  BUS=$(grep -m 1 -i 'bus-info:' <<< "$result" | awk '{print $2}')

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
  local arguments="$DNSMASQ_OPTS"

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
    arguments+=" --dhcp-host=$mac,,$ip,$host,infinite"

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

  # Set pid file
  arguments+=" --pid-file=$DNSMASQ_PID"

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

  local list="${HOST_PORTS// /},"

  # Remove duplicates
  list=$(echo "${list//,,/,}," | awk 'BEGIN{RS=ORS=","} !seen[$0]++' | sed 's/,*$//g')

  echo "$list"
  return 0
}

getUserPorts() {

  local ssh="22"
  local dsm="5000,5001"

  local list="$ssh,$dsm,"
  list+="${USER_PORTS// /},"

  local exclude
  exclude=$(getHostPorts)

  local ports=""
  local userport=""
  local hostport=""

  for userport in ${list//,/ }; do

    local num="${userport///tcp}"
    num="${num///udp}"

    for hostport in ${exclude//,/ }; do

      local port="${hostport///tcp}"
      port="${port///udp}"

      if [[ "$num" == "$port" ]]; then
        num=""
        if [[ "$port" != "$WEB_PORT" ]]; then
          warn "Could not assign port $port to \"USER_PORTS\" because it is already in \"HOST_PORTS\"!"
        fi
      fi

    done

    [ -n "$num" ] && ports+="$userport,"

  done

  # Remove duplicates
  echo "${ports//,,/,}," | awk 'BEGIN{RS=ORS=","} !seen[$0]++' | sed 's/,*$//g'
  return 0
}

getSlirp() {

  local ip="$1"
  local args=""
  local list=""

  list=$(getUserPorts)

  for port in ${list//,/ }; do

    local proto="tcp"
    local num="${port%/tcp}"
    [ -z "$num" ] && continue

    if [[ "$port" == *"/udp" ]]; then
      proto="udp"
      num="${port%/udp}"
    elif [[ "$port" != *"/tcp" ]]; then
      args+="hostfwd=$proto::$num-$ip:$num,"
      proto="udp"
      num="${port%/udp}"
    fi

    args+="hostfwd=$proto::$num-$ip:$num,"
  done

  echo "$args" | sed 's/,*$//g'
  return 0
}

# ######################################
#  Network mode setup
# ######################################

configureDHCP() {

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
    echo "$gateway" > /run/shm/qemu.gw || warn "Failed to write gateway file."
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

  local log="/tmp/passt.log"
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
  forward=$(getUserPorts)
  forward="${forward///tcp}"
  forward="${forward///udp}"

  if [ -n "$forward" ]; then
    forward="%${DEV}/$forward"
    PASST_OPTS+=" -t $forward"
    PASST_OPTS+=" -u $forward"
  fi

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
  else
    if enabled "$DEBUG"; then
      [ -f "$log" ] && [ -s "$log" ] && cat "$log" && echo ""
    fi
  fi

  NET_OPTS="-netdev stream,id=hostnet0,server=off,addr.type=unix,addr.path=$PASST_SOCKET"

  configureDNS "lo" "$ip" "$MAC" "$HOST" "$MASK" "$gateway" || return 1

  IP="$ip"
  return 0
}

createBridge() {

  local gateway="$1"
  local rc

  # Create a bridge with a static IP for the VM guest
  { ip link add dev "$BRIDGE" type bridge; rc=$?; } || :

  if (( rc != 0 )); then
    enabled "$ROOTLESS" && ! enabled "$DEBUG" && return 1
    warn "failed to create bridge. $ADD_ERR --cap-add NET_ADMIN" && return 1
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

  # Set tap to the bridge created
  if ! ip tuntap add dev "$TAP" mode tap; then
    enabled "$ROOTLESS" && ! enabled "$DEBUG" && return 1
    warn "$tuntap" && return 1
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

configureTables() {

  local ip="$1"
  local subnet="$2"
  local exclude="$3"
  local rule_tag="remove"
  local tables_err="failed to configure IP tables!"
  local tables="the 'ip_tables' kernel module is not loaded. Try this command: sudo modprobe ip_tables iptable_nat"

  clearTables

  if [ -n "$exclude" ]; then
    if [[ "$exclude" != *","* ]]; then
      exclude=" ! --dport $exclude"
    else
      exclude=" -m multiport ! --dports $exclude"
    fi
  fi

  # NAT traffic from bridge subnet to Docker uplink
  if ! iptables -t nat -A POSTROUTING \
    -o "$DEV" \
    -s "$subnet" \
    ! -d "$subnet" \
    -m comment --comment "$rule_tag" \
    -j MASQUERADE > /dev/null 2>&1; then
    enabled "$ROOTLESS" && ! enabled "$DEBUG" && return 1
    if ! iptables -t nat -A POSTROUTING \
      -o "$DEV" \
      -s "$subnet" \
      ! -d "$subnet" \
      -m comment --comment "$rule_tag" \
      -j MASQUERADE; then
      warn "$tables" && return 1
    fi
  fi

  # shellcheck disable=SC2086
  if ! iptables -t nat -A PREROUTING \
    -i "$DEV" \
    -d "$UPLINK" \
    -p tcp${exclude} \
    -m comment --comment "$rule_tag" \
    -j DNAT --to "$ip"; then
    warn "$tables_err" && return 1
  fi

  if ! iptables -t nat -A PREROUTING \
    -i "$DEV" \
    -d "$UPLINK" \
    -p udp \
    -m comment --comment "$rule_tag" \
    -j DNAT --to "$ip"; then
    warn "$tables_err" && return 1
  fi

  if (( KERNEL > 4 )); then
    # Hack for guest VMs complaining about "bad udp checksums in 5 packets"
    iptables -t mangle -A POSTROUTING \
      -s "$subnet" \
      -p udp \
      --dport bootpc \
      -m comment --comment "$rule_tag" \
      -j CHECKSUM --checksum-fill > /dev/null 2>&1 || true
  fi

  # Clamp TCP MSS to avoid subtle MTU blackholes when the outer path has a smaller MTU.
  iptables -t mangle -A FORWARD \
    -s "$subnet" \
    -p tcp \
    --tcp-flags SYN,RST SYN \
    -m comment --comment "$rule_tag" \
    -j TCPMSS --clamp-mss-to-pmtu > /dev/null 2>&1 || true

  iptables -t mangle -A FORWARD \
    -d "$ip" \
    -p tcp \
    --tcp-flags SYN,RST SYN \
    -m comment --comment "$rule_tag" \
    -j TCPMSS --clamp-mss-to-pmtu > /dev/null 2>&1 || true

  # Allow forwarding from bridge -> dev
  if ! iptables -A FORWARD \
    -i "$BRIDGE" \
    -o "$DEV" \
    -m comment --comment "$rule_tag" \
    -j ACCEPT; then
    warn "$tables_err" && return 1
  fi

  # Allow return traffic
  if ! iptables -A FORWARD \
    -i "$DEV" \
    -o "$BRIDGE" \
    -m conntrack --ctstate RELATED,ESTABLISHED \
    -m comment --comment "$rule_tag" \
    -j ACCEPT; then
    warn "$tables_err" && return 1
  fi

  return 0
}

configureNAT() {

  local tuntap="TUN device is missing. $ADD_ERR --device /dev/net/tun"

  enabled "$DEBUG" && echo "Configuring NAT networking..."

  # Create the necessary file structure for /dev/net/tun
  if [ ! -c /dev/net/tun ]; then
    [ ! -d /dev/net ] && mkdir -m 755 /dev/net
    if mknod /dev/net/tun c 10 200; then
      chmod 666 /dev/net/tun
    fi
  fi

  if [ ! -c /dev/net/tun ]; then
    enabled "$ROOTLESS" && ! enabled "$DEBUG" && return 1
    warn "$tuntap" && return 1
  fi

  # Check port forwarding flag
  if [[ $(< /proc/sys/net/ipv4/ip_forward) -eq 0 ]]; then
    { sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1; rc=$?; } || :
    if (( rc != 0 )) || [[ $(< /proc/sys/net/ipv4/ip_forward) -eq 0 ]]; then
      enabled "$ROOTLESS" && ! enabled "$DEBUG" && return 1
      warn "IP forwarding is disabled. $ADD_ERR --sysctl net.ipv4.ip_forward=1"
      return 1
    fi
  fi

  local ip exclude subnet

  if [ -n "$IP" ]; then
    ip=$(guestIP "$IP" 2)
  else
    ip=$(natGuestIP "$UPLINK")
  fi

  local gateway="${ip%.*}.1"
  subnet=$(networkCIDR "$ip") || return 1

  if ip route show "$subnet" 2>/dev/null | grep -q .; then
    error "VM subnet $subnet conflicts with an existing route inside the container."
    return 1
  fi

  createBridge "$gateway" || return 1
  createTap "$tuntap" || return 1

  # Use the lowest effective guest-facing MTU, without mutating the parent/uplink MTU.
  if [[ "$GUEST_MTU" != "0" ]]; then
    GUEST_MTU=$(minMTU "$GUEST_MTU" "$(getMTU "$BRIDGE")" "$(getMTU "$TAP")")
  fi

  exclude=$(getHostPorts)
  configureTables "$ip" "$subnet" "$exclude" || return 1

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

clearTables() {
  local table="" line rules
  local rule_tag="remove"

  # Choose between iptables or nftables
  if command -v iptables-nft >/dev/null 2>&1 && iptables-nft -V >/dev/null 2>&1; then
    update-alternatives --set iptables /usr/sbin/iptables-nft > /dev/null
    update-alternatives --set ip6tables /usr/sbin/ip6tables-nft > /dev/null
  else
    update-alternatives --set iptables /usr/sbin/iptables-legacy > /dev/null
    update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy > /dev/null
  fi

  # Store the current iptables ruleset
  ! rules=$(iptables-save 2> /dev/null) && return 0
  [ -z "$rules" ] && return 0

  # Delete every rule tagged with our unique identifier, leaving all other rules intact.
  while IFS= read -r line; do
    case "$line" in
      \*nat)    table="nat" ;;
      \*filter) table="filter" ;;
      \*mangle) table="mangle" ;;
      \*raw)    table="raw" ;;
    esac
    if [[ "$line" == -A* ]]; then
      if [[ "$line" == *"--comment $rule_tag"* || "$line" == *"--comment \"$rule_tag\""* ]]; then
        read -ra args <<< "${line/-A /-D }"
        iptables -t "$table" "${args[@]}" &> /dev/null || :
      fi
    fi
  done <<< "$rules"

  return 0
}

closeBridge() {

  local pids=( "$PASST_PID" "$DNSMASQ_PID" )
  mKill "${pids[@]}"

  ip link set "$TAP" down promisc off &> /dev/null || :
  ip link delete "$TAP" &> /dev/null || :

  ip link set "$BRIDGE" down &> /dev/null || :
  ip link delete "$BRIDGE" &> /dev/null || :

  clearTables
  return 0
}

closeWeb() {

  local pids=( "$WEB_PID" "$WSD_PID" )
  mKill "${pids[@]}"

  return 0
}

closeNetwork() {

  if ! disabled "${WEB:-}" && enabled "$DHCP"; then
    closeWeb
  fi

  disabled "$NETWORK" && return 0

  exec 30>&- 2>/dev/null || true
  exec 40>&- 2>/dev/null || true

  closeBridge

  return 0
}

cleanUp() {

  closeBridge

  # Clean up old files
  rm -f "$PASST_PID" "$PASST_SOCKET"
  rm -f "$DNSMASQ_PID" /etc/resolv.dnsmasq

  return 0
}

# ######################################
#  Detection
# ######################################

checkOS() {

  local os=""
  local kernel=""
  local iface="macvlan"

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

      BNF="/proc/sys/net/bridge/bridge-nf-call-iptables"

      if [[ -r "$BNF" ]] && [[ "$(<"$BNF")" != "0" ]]; then
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
    [ -s "$file" ] && MAC=$(<"$file")
    MAC="${MAC//[![:print:]]/}"

    if [ -z "$MAC" ]; then
      # Generate a Synology-style MAC address based on a stable container identifier when possible.
      MAC=$(echo "$container" | md5sum | sed 's/^\(..\)\(..\)\(..\)\(..\)\(..\).*$/02:11:32:\3:\4:\5/')
      echo "${MAC^^}" > "$file"
      ! setOwner "$file" && error "Failed to set the owner for \"$file\" !"
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

  # Keep the guest-facing gateway MAC stable across runs, otherwise Windows guests
  # may detect a new network every boot.
  GATEWAY_MAC=$(gatewayMAC "$MAC")

  return 0
}

printNetworkDebug() {

  local line=""
  local host=""
  local nameservers=""

  enabled "$DEBUG" || return 0

  host=$(containerID)

  line="Host: $host  IP: $UPLINK  Gateway: $GATEWAY  Interface: $DEV  MAC: $MAC  MTU: $MTU  Mask: $MASK/$PREFIX"
  info "$line"

  if [ -f /etc/resolv.conf ]; then
    nameservers=$(grep '^nameserver ' /etc/resolv.conf | sed 's/^nameserver //' | paste -sd ',' | sed 's/,/, /g')
    [ -n "$nameservers" ] && info "Nameservers: $nameservers"
  fi

  echo
  return 0
}

prepareNetwork() {

  detectInterface
  validateInterface

  validateMask

  detectAddresses
  validateAddresses

  detectAdapter
  validateAdapter

  configureMTU
  configureMAC

  printNetworkDebug

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

prepareNetwork

echo "$UPLINK" > "$QEMU_DIR"/qemu.ip
echo "$NIC" > "$QEMU_DIR"/qemu.nic

cleanUp

if [[ "$UPLINK" == "172.17."* ]]; then
  warn "your container IP starts with 172.17.* which will cause conflicts when you install the Container Manager package inside DSM!"
fi

MSG="Booting DSM instance..."
html "$MSG"

if enabled "$DHCP"; then

  # Configure for macvtap interface
  configureDHCP || exit 20

else

  if ! disabled "${WEB:-}"; then
    sleep 1.2
    closeWeb
  fi

  if isNAT; then

    # Configure tap interface
    if ! configureNAT; then

      closeBridge
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

  if [[ "${NETWORK,,}" == "passt" || "${NETWORK,,}" == "slirp" ]]; then
    if [ -z "$USER_PORTS" ]; then
      info "Notice: because user-mode networking is active, when you need to forward custom ports to DSM, add them to the \"USER_PORTS\" variable."
    fi
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

return 0
