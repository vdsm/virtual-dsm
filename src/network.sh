#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables

: "${MAC:=""}"
: "${MTU:=""}"
: "${DHCP:="N"}"
: "${NETWORK:="Y"}"
: "${HOST_PORTS:=""}"
: "${USER_PORTS:=""}"
: "${ADAPTER:="virtio-net-pci"}"

: "${VM_NET_IP:=""}"
: "${VM_NET_DEV:=""}"
: "${VM_NET_TAP:="dsm"}"
: "${VM_NET_MAC:="$MAC"}"
: "${VM_NET_BRIDGE:="docker"}"
: "${VM_NET_HOST:="VirtualDSM"}"
: "${VM_NET_MASK:="255.255.255.0"}"

: "${PASST:="passt"}"
: "${PASST_MTU:=""}"
: "${PASST_OPTS:=""}"
: "${PASST_DEBUG:=""}"

: "${DNSMASQ_OPTS:=""}"
: "${DNSMASQ_DEBUG:=""}"
: "${DNSMASQ:="/usr/sbin/dnsmasq"}"
: "${DNSMASQ_CONF_DIR:="/etc/dnsmasq.d"}"

ADD_ERR="Please add the following setting to your container:"

# ######################################
#  Functions
# ######################################

configureDHCP() {

  [[ "$DEBUG" == [Yy1]* ]] && echo "Configuring MACVTAP networking..."

  # Create the necessary file structure for /dev/vhost-net
  if [ ! -c /dev/vhost-net ]; then
    if mknod /dev/vhost-net c 10 238; then
      chmod 660 /dev/vhost-net
    fi
  fi

  # Create a macvtap network for the VM guest
  { msg=$(ip link add link "$VM_NET_DEV" name "$VM_NET_TAP" address "$VM_NET_MAC" type macvtap mode bridge 2>&1); rc=$?; } || :

  case "$msg" in
    "RTNETLINK answers: File exists"* )
      while ! ip link add link "$VM_NET_DEV" name "$VM_NET_TAP" address "$VM_NET_MAC" type macvtap mode bridge; do
        info "Waiting for macvtap interface to become available.."
        sleep 5
      done  ;;
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

  if [[ "$MTU" != "0" && "$MTU" != "1500" ]]; then
    if ! ip link set dev "$VM_NET_TAP" mtu "$MTU"; then
      warn "Failed to set MTU size to $MTU."
    fi
  fi

  while ! ip link set "$VM_NET_TAP" up; do
    info "Waiting for MAC address $VM_NET_MAC to become available..."
    info "If you cloned this machine, please delete the 'dsm.mac' file to generate a different MAC address."
    sleep 2
  done

  local TAP_NR TAP_PATH MAJOR MINOR
  TAP_NR=$(</sys/class/net/"$VM_NET_TAP"/ifindex)
  TAP_PATH="/dev/tap${TAP_NR}"

  # Create dev file (there is no udev in container: need to be done manually)
  IFS=: read -r MAJOR MINOR < <(cat /sys/devices/virtual/net/"$VM_NET_TAP"/tap*/dev)
  (( MAJOR < 1)) && error "Cannot find: sys/devices/virtual/net/$VM_NET_TAP" && return 1

  [[ ! -e "$TAP_PATH" && -e "/dev0/${TAP_PATH##*/}" ]] && ln -s "/dev0/${TAP_PATH##*/}" "$TAP_PATH"

  if [[ ! -e "$TAP_PATH" ]]; then
    { mknod "$TAP_PATH" c "$MAJOR" "$MINOR" ; rc=$?; } || :
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

configureDNS() {

  local if="$1"
  local ip="$2"
  local mac="$3"
  local host="$4"
  local mask="$5"
  local gateway="$6"

  echo "$gateway" > /run/shm/qemu.gw
  
  [[ "${DNSMASQ_DISABLE:-}" == [Yy1]* ]] && return 0
  [[ "$DEBUG" == [Yy1]* ]] && echo "Starting dnsmasq daemon..."

  local log="/var/log/dnsmasq.log"
  rm -f "$log"

  case "${NETWORK,,}" in
    "nat" | "tap" | "tun" | "tuntap" | "y" )

      # Create lease file for faster resolve
      echo "0 $mac $ip $host 01:$mac" > /var/lib/misc/dnsmasq.leases
      chmod 644 /var/lib/misc/dnsmasq.leases

      # dnsmasq configuration:
      DNSMASQ_OPTS+=" --dhcp-authoritative"

      # Set DHCP range and host
      DNSMASQ_OPTS+=" --dhcp-range=$ip,$ip"
      DNSMASQ_OPTS+=" --dhcp-host=$mac,,$ip,$host,infinite"

      # Set DNS server and gateway
      DNSMASQ_OPTS+=" --dhcp-option=option:netmask,$mask"
      DNSMASQ_OPTS+=" --dhcp-option=option:router,$gateway"
      DNSMASQ_OPTS+=" --dhcp-option=option:dns-server,$gateway"

  esac

  # Set interfaces
  DNSMASQ_OPTS+=" --interface=$if"
  DNSMASQ_OPTS+=" --bind-interfaces"

  # Add DNS entry for container
  DNSMASQ_OPTS+=" --address=/host.lan/$gateway"

  # Set local dns resolver to dnsmasq when needed
  [ -f /etc/resolv.dnsmasq ] && DNSMASQ_OPTS+=" --resolv-file=/etc/resolv.dnsmasq"

  # Enable logging to file
  DNSMASQ_OPTS+=" --log-facility=$log"

  DNSMASQ_OPTS=$(echo "$DNSMASQ_OPTS" | sed 's/\t/ /g' | tr -s ' ' | sed 's/^ *//')
  [[ "$DEBUG" == [Yy1]* ]] && printf "Dnsmasq arguments:\n\n%s\n\n" "${DNSMASQ_OPTS// -/$'\n-'}"

  if ! $DNSMASQ ${DNSMASQ_OPTS:+ $DNSMASQ_OPTS}; then

    local msg="Failed to start Dnsmasq, reason: $?"
    [ -f "$log" ] && cat "$log"
    error "$msg"

    return 1
  fi

  if [[ "$DNSMASQ_DEBUG" == [Yy1]* ]]; then
    tail -fn +0 "$log" --pid=$$ &
  fi

  return 0
}

getHostPorts() {

  local list="$1"
  list=$(echo "${list// /}" | sed 's/,*$//g')

  [ -z "$list" ] && list="$MON_PORT" || list+=",$MON_PORT"

  echo "$list"
  return 0
}

getUserPorts() {

  local args=""
  local list=$1
  list=$(echo "${list// /}" | sed 's/,*$//g')

  local ssh="22"
  local dsm="5000"
  [ -z "$list" ] && list="$ssh,$dsm" || list+=",$ssh,$dsm"

  echo "$list"
  return 0
}

getSlirp() {

  local args=""
  local list=""

  list=$(getUserPorts "${USER_PORTS:-}")
  list="${list//,/ }"
  list="${list## }"
  list="${list%% }"

  for port in $list; do

    proto="tcp"
    num="${port%/tcp}"

    if [[ "$port" == *"/udp" ]]; then
      proto="udp"
      num="${port%/udp}"
    elif [[ "$port" != *"/tcp" ]]; then
      args+="hostfwd=$proto::$num-$VM_NET_IP:$num,"
      proto="udp"
      num="${port%/udp}"
    fi

    args+="hostfwd=$proto::$num-$VM_NET_IP:$num,"
  done

  echo "${args%?}"
  return 0
}

configureSlirp() {

  [[ "$DEBUG" == [Yy1]* ]] && echo "Configuring slirp networking..."

  local ip="$IP"
  [ -n "$VM_NET_IP" ] && ip="$VM_NET_IP"
  local base="${ip%.*}."
  [ "${ip/$base/}" -lt "4" ] && ip="${ip%.*}.4"
  local gateway="${ip%.*}.1"

  local ipv6=""
  [ -n "$IP6" ] && ipv6="ipv6=on,"

  NET_OPTS="-netdev user,id=hostnet0,ipv4=on,host=$gateway,net=${gateway%.*}.0/24,dhcpstart=$ip,${ipv6}hostname=$VM_NET_HOST"

  local forward=""
  forward=$(getSlirp)
  [ -n "$forward" ] && NET_OPTS+=",$forward"

  if [[ "${DNSMASQ_DISABLE:-}" == [Yy1]* ]]; then
    echo "$gateway" > /run/shm/qemu.gw
  else
    cp /etc/resolv.conf /etc/resolv.dnsmasq
    configureDNS "lo" "$ip" "$VM_NET_MAC" "$VM_NET_HOST" "$VM_NET_MASK" "$gateway" || return 1
    echo -e "nameserver 127.0.0.1\nsearch .\noptions ndots:0" >/etc/resolv.conf
  fi

  VM_NET_IP="$ip"
  return 0
}

configurePasst() {

  [[ "$DEBUG" == [Yy1]* ]] && echo "Configuring user-mode networking..."

  local log="/var/log/passt.log"
  rm -f "$log"

  local pid="/var/run/dnsmasq.pid"
  [ -s "$pid" ] && pKill "$(<"$pid")"

  local ip="$IP"
  [ -n "$VM_NET_IP" ] && ip="$VM_NET_IP"

  local gateway=""
  if [[ "$ip" != *".1" ]]; then
    gateway="${ip%.*}.1"
  else
    gateway="${ip%.*}.2"
  fi

  # passt configuration:
  [ -z "$IP6" ] && PASST_OPTS+=" -4"

  PASST_OPTS+=" -a $ip"
  PASST_OPTS+=" -g $gateway"
  PASST_OPTS+=" -n $VM_NET_MASK"
  [ -n "$PASST_MTU" ] && PASST_OPTS+=" -m $PASST_MTU"

  local forward=""
  forward=$(getUserPorts "${USER_PORTS:-}")
  forward="${forward///tcp}"
  forward="${forward///udp}"

  if [ -n "$forward" ]; then
    forward="%${VM_NET_DEV}/$forward"
    PASST_OPTS+=" -t $forward"
    PASST_OPTS+=" -u $forward"
  fi

  PASST_OPTS+=" -H $VM_NET_HOST"
  PASST_OPTS+=" -M $GATEWAY_MAC"
  PASST_OPTS+=" -P /var/run/passt.pid"
  PASST_OPTS+=" -l $log"
  PASST_OPTS+=" -q"

  if [[ "${DNSMASQ_DISABLE:-}" != [Yy1]* ]]; then
    cp /etc/resolv.conf /etc/resolv.dnsmasq
    echo -e "nameserver 127.0.0.1\nsearch .\noptions ndots:0" >/etc/resolv.conf
  fi

  PASST_OPTS=$(echo "$PASST_OPTS" | sed 's/\t/ /g' | tr -s ' ' | sed 's/^ *//')
  [[ "$DEBUG" == [Yy1]* ]] && printf "Passt arguments:\n\n%s\n\n" "${PASST_OPTS// -/$'\n-'}"

  if ! $PASST ${PASST_OPTS:+ $PASST_OPTS} >/dev/null 2>&1; then

    rm -f "$log"
    PASST_OPTS="${PASST_OPTS/ -q/}"
    { $PASST ${PASST_OPTS:+ $PASST_OPTS}; rc=$?; } || :

    if (( rc != 0 )); then
      [ -f "$log" ] && cat "$log"
      error "Failed to start passt, reason: $rc"
      return 1
    fi

  fi

  if [[ "$PASST_DEBUG" == [Yy1]* ]]; then
    tail -fn +0 "$log" --pid=$$ &
  else
    if [[ "$DEBUG" == [Yy1]* ]]; then
      [ -f "$log" ] && cat "$log" && echo ""
    fi
  fi

  NET_OPTS="-netdev stream,id=hostnet0,server=off,addr.type=unix,addr.path=/tmp/passt_1.socket"

  configureDNS "lo" "$ip" "$VM_NET_MAC" "$VM_NET_HOST" "$VM_NET_MASK" "$gateway" || return 1

  VM_NET_IP="$ip"
  return 0
}

configureNAT() {

  local tuntap="TUN device is missing. $ADD_ERR --device /dev/net/tun"
  local tables="the 'ip_tables' kernel module is not loaded. Try this command: sudo modprobe ip_tables iptable_nat"

  [[ "$DEBUG" == [Yy1]* ]] && echo "Configuring NAT networking..."

  # Create the necessary file structure for /dev/net/tun
  if [ ! -c /dev/net/tun ]; then
    [[ "$PODMAN" == [Yy1]* ]] && return 1
    [ ! -d /dev/net ] && mkdir -m 755 /dev/net
    if mknod /dev/net/tun c 10 200; then
      chmod 666 /dev/net/tun
    fi
  fi

  if [ ! -c /dev/net/tun ]; then
    warn "$tuntap" && return 1
  fi

  # Check port forwarding flag
  if [[ $(< /proc/sys/net/ipv4/ip_forward) -eq 0 ]]; then
    { sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1; rc=$?; } || :
    if (( rc != 0 )) || [[ $(< /proc/sys/net/ipv4/ip_forward) -eq 0 ]]; then
      warn "IP forwarding is disabled. $ADD_ERR --sysctl net.ipv4.ip_forward=1"
      return 1
    fi
  fi

  local ip base
  base=$(echo "$IP" | sed -r 's/([^.]*.){2}//')
  if [[ "$IP" != "172.30."* ]]; then
    ip="172.30.$base"
  else
    ip="172.31.$base"
  fi

  [ -n "$VM_NET_IP" ] && ip="$VM_NET_IP"

  local gateway=""
  if [[ "$ip" != *".1" ]]; then
    gateway="${ip%.*}.1"
  else
    gateway="${ip%.*}.2"
  fi

  # Create a bridge with a static IP for the VM guest
  { ip link add dev "$VM_NET_BRIDGE" type bridge ; rc=$?; } || :

  if (( rc != 0 )); then
    warn "failed to create bridge. $ADD_ERR --cap-add NET_ADMIN" && return 1
  fi

  if ! ip address add "$gateway/24" broadcast "${ip%.*}.255" dev "$VM_NET_BRIDGE"; then
    warn "failed to add IP address pool!" && return 1
  fi

  while ! ip link set "$VM_NET_BRIDGE" up; do
    info "Waiting for IP address to become available..."
    sleep 2
  done

  # QEMU Works with taps, set tap to the bridge created
  if ! ip tuntap add dev "$VM_NET_TAP" mode tap; then
    warn "$tuntap" && return 1
  fi

  if [[ "$MTU" != "0" && "$MTU" != "1500" ]]; then
    if ! ip link set dev "$VM_NET_TAP" mtu "$MTU"; then
      warn "failed to set MTU size to $MTU."
    fi
  fi

  if ! ip link set dev "$VM_NET_TAP" address "$GATEWAY_MAC"; then
    warn "failed to set gateway MAC address.."
  fi

  while ! ip link set "$VM_NET_TAP" up promisc on; do
    info "Waiting for TAP to become available..."
    sleep 2
  done

  if ! ip link set dev "$VM_NET_TAP" master "$VM_NET_BRIDGE"; then
    warn "failed to set master bridge!" && return 1
  fi

  if grep -wq "nf_tables" /proc/modules; then
    update-alternatives --set iptables /usr/sbin/iptables-nft > /dev/null
    update-alternatives --set ip6tables /usr/sbin/ip6tables-nft > /dev/null
  else
    update-alternatives --set iptables /usr/sbin/iptables-legacy > /dev/null
    update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy > /dev/null
  fi

  exclude=$(getHostPorts "$HOST_PORTS")

  if [ -n "$exclude" ]; then
    if [[ "$exclude" != *","* ]]; then
      exclude=" ! --dport $exclude"
    else
      exclude=" -m multiport ! --dports $exclude"
    fi
  fi

  if ! iptables -t nat -A POSTROUTING -o "$VM_NET_DEV" -j MASQUERADE; then
    warn "$tables" && return 1
  fi

  # shellcheck disable=SC2086
  if ! iptables -t nat -A PREROUTING -i "$VM_NET_DEV" -d "$IP" -p tcp${exclude} -j DNAT --to "$ip"; then
    warn "failed to configure IP tables!" && return 1
  fi

  if ! iptables -t nat -A PREROUTING -i "$VM_NET_DEV" -d "$IP" -p udp -j DNAT --to "$ip"; then
    warn "failed to configure IP tables!" && return 1
  fi

  if (( KERNEL > 4 )); then
    # Hack for guest VMs complaining about "bad udp checksums in 5 packets"
    iptables -A POSTROUTING -t mangle -p udp --dport bootpc -j CHECKSUM --checksum-fill > /dev/null 2>&1 || true
  fi

  NET_OPTS="-netdev tap,id=hostnet0,ifname=$VM_NET_TAP"

  if [ -c /dev/vhost-net ]; then
    { exec 40>>/dev/vhost-net; rc=$?; } 2>/dev/null || :
    (( rc == 0 )) && NET_OPTS+=",vhost=on,vhostfd=40"
  fi

  NET_OPTS+=",script=no,downscript=no"

  configureDNS "$VM_NET_BRIDGE" "$ip" "$VM_NET_MAC" "$VM_NET_HOST" "$VM_NET_MASK" "$gateway" || return 1

  VM_NET_IP="$ip"
  return 0
}

closeBridge() {

  local pid="/var/run/dnsmasq.pid"
  [ -s "$pid" ] && pKill "$(<"$pid")"
  rm -f "$pid"

  pid="/var/run/passt.pid"
  [ -s "$pid" ] && pKill "$(<"$pid")"
  rm -f "$pid"

  case "${NETWORK,,}" in
    "user"* | "passt" | "slirp" ) return 0 ;;
  esac

  ip link set "$VM_NET_TAP" down promisc off &> null || true
  ip link delete "$VM_NET_TAP" &> null || true

  ip link set "$VM_NET_BRIDGE" down &> null || true
  ip link delete "$VM_NET_BRIDGE" &> null || true

  return 0
}

closeWeb() {

  # Shutdown nginx
  nginx -s stop 2> /dev/null
  fWait "nginx"

  # Shutdown websocket
  local pid="/var/run/websocketd.pid"
  [ -s "$pid" ] && pKill "$(<"$pid")"
  rm -f "$pid"

  return 0
}

closeNetwork() {

  if [[ "${WEB:-}" != [Nn]* && "$DHCP" == [Yy1]* ]]; then
    closeWeb
  fi

  [[ "$NETWORK" == [Nn]* ]] && return 0

  exec 30<&- || true
  exec 40<&- || true

  if [[ "$DHCP" != [Yy1]* ]]; then

    closeBridge
    return 0

  fi

  ip link set "$VM_NET_TAP" down || true
  ip link delete "$VM_NET_TAP" || true

  return 0
}

cleanUp() {

  # Clean up old files
  rm -f /etc/resolv.dnsmasq
  rm -f /var/run/passt.pid
  rm -f /var/run/dnsmasq.pid

  if [[ -d "/sys/class/net/$VM_NET_TAP" ]]; then
    info "Lingering interface will be removed..."
    ip link delete "$VM_NET_TAP" || true
  fi

  return 0
}

checkOS() {

  local kernel
  local os=""
  local if="macvlan"
  kernel=$(uname -a)

  [[ "${kernel,,}" == *"darwin"* ]] && os="$ENGINE Desktop for macOS"
  [[ "${kernel,,}" == *"microsoft"* ]] && os="$ENGINE Desktop for Windows"

  if [[ "$DHCP" == [Yy1]* ]]; then
    if="macvtap"
    [[ "${kernel,,}" == *"synology"* ]] && os="Synology Container Manager"
  fi

  if [ -n "$os" ]; then
    warn "you are using $os which does not support $if, please revert to bridge networking!"
  fi

  return 0
}

getInfo() {

  if [ -z "$VM_NET_DEV" ]; then
    # Give Kubernetes priority over the default interface
    [ -d "/sys/class/net/net0" ] && VM_NET_DEV="net0"
    [ -d "/sys/class/net/net1" ] && VM_NET_DEV="net1"
    [ -d "/sys/class/net/net2" ] && VM_NET_DEV="net2"
    [ -d "/sys/class/net/net3" ] && VM_NET_DEV="net3"
    # Automaticly detect the default network interface
    [ -z "$VM_NET_DEV" ] && VM_NET_DEV=$(awk '$2 == 00000000 { print $1 }' /proc/net/route)
    [ -z "$VM_NET_DEV" ] && VM_NET_DEV="eth0"
  fi

  if [ ! -d "/sys/class/net/$VM_NET_DEV" ]; then
    error "Network interface '$VM_NET_DEV' does not exist inside the container!"
    error "$ADD_ERR -e \"VM_NET_DEV=NAME\" to specify another interface name." && exit 26
  fi

  GATEWAY=$(ip route list dev "$VM_NET_DEV" | awk ' /^default/ {print $3}' | head -n 1)
  { IP=$(ip address show dev "$VM_NET_DEV" | grep inet | awk '/inet / { print $2 }' | cut -f1 -d/ | head -n 1); rc=$?; } 2>/dev/null || :

  if (( rc != 0 )); then
    error "Could not determine container IP address!" && exit 26
  fi

  IP6=""
  # shellcheck disable=SC2143
  if [ -f /proc/net/if_inet6 ] && [ -n "$(ifconfig -a | grep inet6)" ]; then
    { IP6=$(ip -6 addr show dev "$VM_NET_DEV" scope global up); rc=$?; } 2>/dev/null || :
    (( rc != 0 )) && IP6=""
    [ -n "$IP6" ] && IP6=$(echo "$IP6" | sed -e's/^.*inet6 \([^ ]*\)\/.*$/\1/;t;d' | head -n 1)
  fi

  local result nic bus
  result=$(ethtool -i "$VM_NET_DEV")
  nic=$(grep -m 1 -i 'driver:' <<< "$result" | awk '{print $(2)}')
  bus=$(grep -m 1 -i 'bus-info:' <<< "$result" | awk '{print $(2)}')

  if [[ "${bus,,}" != "" && "${bus,,}" != "n/a" && "${bus,,}" != "tap" ]]; then
    [[ "$DEBUG" == [Yy1]* ]] && info "Detected BUS: $bus"
    error "This container does not support host mode networking!"
    exit 29
  fi

  if [[ "$DHCP" == [Yy1]* ]]; then

    checkOS

    if [[ "${nic,,}" == "ipvlan" ]]; then
      error "This container does not support IPVLAN networking when DHCP=Y."
      exit 29
    fi

    if [[ "${nic,,}" != "macvlan" ]]; then
      [[ "$DEBUG" == [Yy1]* ]] && info "Detected NIC: $nic"
      error "The container needs to be in a MACVLAN network when DHCP=Y."
      exit 29
    fi

  else

    if [[ "$IP" != "172."* && "$IP" != "10.8"* && "$IP" != "10.9"* ]]; then
      checkOS
    fi

  fi

  local mtu=""

  if [ -f "/sys/class/net/$VM_NET_DEV/mtu" ]; then
    mtu=$(< "/sys/class/net/$VM_NET_DEV/mtu")
  fi

  [ -z "$MTU" ] && MTU="$mtu"
  [ -z "$MTU" ] && MTU="0"

  if [[ "${ADAPTER,,}" != "virtio-net-pci" ]]; then
    if [[ "$MTU" != "0" && "$MTU" != "1500" ]]; then
      warn "MTU size is $MTU, but cannot be set for $ADAPTER adapters!" && MTU="0"
    fi
  fi

  if [ -z "$VM_NET_MAC" ]; then
    local file="$STORAGE/dsm.mac"
    [ -s "$file" ] && VM_NET_MAC=$(<"$file")
    VM_NET_MAC="${VM_NET_MAC//[![:print:]]/}"
    if [ -z "$VM_NET_MAC" ]; then
      # Generate MAC address based on Docker container ID in hostname
      VM_NET_MAC=$(echo "$HOST" | md5sum | sed 's/^\(..\)\(..\)\(..\)\(..\)\(..\).*$/02:11:32:\3:\4:\5/')
      echo "${VM_NET_MAC^^}" > "$file"
    fi
  fi

  VM_NET_MAC="${VM_NET_MAC^^}"
  VM_NET_MAC="${VM_NET_MAC//-/:}"

  if [[ ${#VM_NET_MAC} == 12 ]]; then
    m="$VM_NET_MAC"
    VM_NET_MAC="${m:0:2}:${m:2:2}:${m:4:2}:${m:6:2}:${m:8:2}:${m:10:2}"
  fi

  if [[ ${#VM_NET_MAC} != 17 ]]; then
    error "Invalid MAC address: '$VM_NET_MAC', should be 12 or 17 digits long!" && exit 28
  fi

  GATEWAY_MAC=$(echo "$VM_NET_MAC" | md5sum | sed 's/^\(..\)\(..\)\(..\)\(..\)\(..\).*$/02:\1:\2:\3:\4:\5/')

  if [[ "$PODMAN" == [Yy1]* && "$DHCP" != [Yy1]* ]]; then
    if [ -z "$NETWORK" ] || [[ "${NETWORK^^}" == "Y" ]]; then
      # By default Podman has no permissions for NAT networking
      NETWORK="user"
    fi
  fi

  if [[ "$DEBUG" == [Yy1]* ]]; then
    line="Host: $HOST  IP: $IP  Gateway: $GATEWAY  Interface: $VM_NET_DEV  MAC: $VM_NET_MAC  MTU: $mtu"
    [[ "$MTU" != "0" && "$MTU" != "$mtu" ]] && line+=" ($MTU)"
    info "$line"
    if [ -f /etc/resolv.conf ]; then
      nameservers=$(grep '^nameserver*' /etc/resolv.conf | head -c -1 | sed 's/nameserver //g;' | sed -z 's/\n/, /g')
      [ -n "$nameservers" ] && info "Nameservers: $nameservers"
    fi
    echo
  fi

  echo "$IP" > /run/shm/qemu.ip
  echo "$nic" > /run/shm/qemu.nic

  return 0
}

# ######################################
#  Configure Network
# ######################################

if [[ "$NETWORK" == [Nn]* ]]; then
  NET_OPTS=""
  return 0
fi

msg="Initializing network..."
html "$msg"
[[ "$DEBUG" == [Yy1]* ]] && echo "$msg"

getInfo
cleanUp

if [[ "$IP" == "172.17."* ]]; then
  warn "your container IP starts with 172.17.* which will cause conflicts when you install the Container Manager package inside DSM!"
fi

MSG="Booting DSM instance..."
html "$MSG"

if [[ "$DHCP" == [Yy1]* ]]; then

  # Configure for macvtap interface
  configureDHCP || exit 20

else

  if [[ "${WEB:-}" != [Nn]* ]]; then
    sleep 1.2
    closeWeb
  fi

  case "${NETWORK,,}" in
    "user"* | "passt" | "slirp" ) ;;
    "nat" | "tap" | "tun" | "tuntap" | "y" )

      # Configure tap interface
      if ! configureNAT; then

        closeBridge
        NETWORK="user"
        msg="falling back to user-mode networking!"
        msg="failed to setup NAT networking, $msg"

      fi ;;

  esac

  [[ "${NETWORK,,}" == "user"* ]] && NETWORK="passt"

  case "${NETWORK,,}" in
    "nat" | "tap" | "tun" | "tuntap" | "y" ) ;;
    "passt" )

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

    *)
      error "Unrecognized NETWORK value: \"$NETWORK\"" && exit 24 ;;
  esac

  case "${NETWORK,,}" in
    "passt" | "slirp" )

      if [ -z "$USER_PORTS" ]; then
        info "Notice: because user-mode networking is active, if you need to expose ports, add them to the \"USER_PORTS\" variable."
      fi ;;

  esac

fi

NET_OPTS+=" -device $ADAPTER,id=net0,netdev=hostnet0,romfile=,mac=$VM_NET_MAC"
[[ "$MTU" != "0" && "$MTU" != "1500" ]] && NET_OPTS+=",host_mtu=$MTU"

return 0
