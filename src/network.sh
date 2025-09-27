#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables

: "${MAC:=""}"
: "${MTU:=""}"
: "${DHCP:="N"}"
: "${NETWORK:="Y"}"
: "${USER_PORTS:=""}"
: "${HOST_PORTS:=""}"
: "${ADAPTER:="virtio-net-pci"}"

: "${VM_NET_DEV:=""}"
: "${VM_NET_TAP:="dsm"}"
: "${VM_NET_MAC:="$MAC"}"
: "${VM_NET_IP:="20.20.20.21"}"
: "${VM_NET_HOST:="VirtualDSM"}"

: "${DNSMASQ_OPTS:=""}"
: "${DNSMASQ:="/usr/sbin/dnsmasq"}"
: "${DNSMASQ_CONF_DIR:="/etc/dnsmasq.d"}"

ADD_ERR="Please add the following setting to your container:"

# ######################################
#  Functions
# ######################################

configureDHCP() {

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
      warn "Failed to set MTU size.."
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

  # Create lease file for faster resolve
  echo "0 $VM_NET_MAC $VM_NET_IP $VM_NET_HOST 01:$VM_NET_MAC" > /var/lib/misc/dnsmasq.leases
  chmod 644 /var/lib/misc/dnsmasq.leases

  # dnsmasq configuration:
  DNSMASQ_OPTS+=" --dhcp-authoritative"

  # Set DHCP range and host
  DNSMASQ_OPTS+=" --dhcp-range=$VM_NET_IP,$VM_NET_IP"
  DNSMASQ_OPTS+=" --dhcp-host=$VM_NET_MAC,,$VM_NET_IP,$VM_NET_HOST,infinite"

  # Set DNS server and gateway
  DNSMASQ_OPTS+=" --dhcp-option=option:netmask,255.255.255.0"
  DNSMASQ_OPTS+=" --dhcp-option=option:router,${VM_NET_IP%.*}.1"
  DNSMASQ_OPTS+=" --dhcp-option=option:dns-server,${VM_NET_IP%.*}.1"

  # Add DNS entry for container
  DNSMASQ_OPTS+=" --address=/host.lan/${VM_NET_IP%.*}.1"

  DNSMASQ_OPTS=$(echo "$DNSMASQ_OPTS" | sed 's/\t/ /g' | tr -s ' ' | sed 's/^ *//')

  if [[ "${DEBUG_DNS:-}" == [Yy1]* ]]; then
   DNSMASQ_OPTS+=" -d"
   $DNSMASQ ${DNSMASQ_OPTS:+ $DNSMASQ_OPTS} &
   return 0
  fi

  if ! $DNSMASQ ${DNSMASQ_OPTS:+ $DNSMASQ_OPTS}; then
    error "Failed to start dnsmasq, reason: $?" && return 1
  fi

  return 0
}

getUserPorts() {

  local args=""
  local list=$1
  local ssh="22"
  local dsm="5000"

  [ -z "$list" ] && list="$ssh,$dsm" || list+=",$ssh,$dsm"

  list="${list//,/ }"
  list="${list## }"
  list="${list%% }"

  for port in $list; do
    proto="tcp"
    num="$port"

    if [[ "$port" == */udp ]]; then
      proto="udp"
      num="${port%/udp}"
    elif [[ "$port" == */tcp ]]; then
      proto="tcp"
      num="${port%/tcp}"
    fi

    args+="hostfwd=$proto::$num-$VM_NET_IP:$num,"
  done

  echo "${args%?}"
  return 0
}

getHostPorts() {

  local list="$1"

  [ -z "$list" ] && echo "" && return 0

  if [[ "$list" != *","* ]]; then
    echo " ! --dport $list"
  else
    echo " -m multiport ! --dports $list"
  fi

  return 0
}

configureUser() {

  if [ -z "$IP6" ]; then
    NET_OPTS="-netdev user,id=hostnet0,host=${VM_NET_IP%.*}.1,net=${VM_NET_IP%.*}.0/24,dhcpstart=$VM_NET_IP,hostname=$VM_NET_HOST"
  else
    NET_OPTS="-netdev user,id=hostnet0,ipv4=on,host=${VM_NET_IP%.*}.1,net=${VM_NET_IP%.*}.0/24,dhcpstart=$VM_NET_IP,ipv6=on,hostname=$VM_NET_HOST"
  fi

  local forward
  forward=$(getUserPorts "$USER_PORTS")
  [ -n "$forward" ] && NET_OPTS+=",$forward"

  return 0
}

configureNAT() {

  local tuntap="TUN device is missing. $ADD_ERR --device /dev/net/tun"
  local tables="The 'ip_tables' kernel module is not loaded. Try this command: sudo modprobe ip_tables iptable_nat"

  # Create the necessary file structure for /dev/net/tun
  if [ ! -c /dev/net/tun ]; then
    [[ "$PODMAN" == [Yy1]* ]] && return 1
    [ ! -d /dev/net ] && mkdir -m 755 /dev/net
    if mknod /dev/net/tun c 10 200; then
      chmod 666 /dev/net/tun
    fi
  fi

  if [ ! -c /dev/net/tun ]; then
    error "$tuntap" && return 1
  fi

  # Check port forwarding flag
  if [[ $(< /proc/sys/net/ipv4/ip_forward) -eq 0 ]]; then
    { sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1; rc=$?; } || :
    if (( rc != 0 )) || [[ $(< /proc/sys/net/ipv4/ip_forward) -eq 0 ]]; then
      [[ "$PODMAN" == [Yy1]* ]] && return 1
      error "IP forwarding is disabled. $ADD_ERR --sysctl net.ipv4.ip_forward=1"
      return 1
    fi
  fi

  # Create a bridge with a static IP for the VM guest
  { ip link add dev dockerbridge type bridge ; rc=$?; } || :

  if (( rc != 0 )); then
    error "Failed to create bridge. $ADD_ERR --cap-add NET_ADMIN" && return 1
  fi

  if ! ip address add "${VM_NET_IP%.*}.1/24" broadcast "${VM_NET_IP%.*}.255" dev dockerbridge; then
    error "Failed to add IP address pool!" && return 1
  fi

  while ! ip link set dockerbridge up; do
    info "Waiting for IP address to become available..."
    sleep 2
  done

  # QEMU Works with taps, set tap to the bridge created
  if ! ip tuntap add dev "$VM_NET_TAP" mode tap; then
    error "$tuntap" && return 1
  fi

  if [[ "$MTU" != "0" && "$MTU" != "1500" ]]; then
    if ! ip link set dev "$VM_NET_TAP" mtu "$MTU"; then
      warn "Failed to set MTU size.."
    fi
  fi

  GATEWAY_MAC=$(echo "$VM_NET_MAC" | md5sum | sed 's/^\(..\)\(..\)\(..\)\(..\)\(..\).*$/02:\1:\2:\3:\4:\5/')

  if ! ip link set dev "$VM_NET_TAP" address "$GATEWAY_MAC"; then
    warn "Failed to set gateway MAC address.."
  fi

  while ! ip link set "$VM_NET_TAP" up promisc on; do
    info "Waiting for TAP to become available..."
    sleep 2
  done

  if ! ip link set dev "$VM_NET_TAP" master dockerbridge; then
    error "Failed to set IP link!" && return 1
  fi

  # Add internet connection to the VM
  update-alternatives --set iptables /usr/sbin/iptables-legacy > /dev/null
  update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy > /dev/null

  exclude=$(getHostPorts "$HOST_PORTS")

  if ! iptables -t nat -A POSTROUTING -o "$VM_NET_DEV" -j MASQUERADE; then
    error "$tables" && return 1
  fi

  # shellcheck disable=SC2086
  if ! iptables -t nat -A PREROUTING -i "$VM_NET_DEV" -d "$IP" -p tcp${exclude} -j DNAT --to "$VM_NET_IP"; then
    error "Failed to configure IP tables!" && return 1
  fi

  if ! iptables -t nat -A PREROUTING -i "$VM_NET_DEV" -d "$IP" -p udp -j DNAT --to "$VM_NET_IP"; then
    error "Failed to configure IP tables!" && return 1
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

  configureDNS || return 1

  return 0
}

closeBridge() {

  local pid="/var/run/dnsmasq.pid"
  [ -s "$pid" ] && pKill "$(<"$pid")"

  [[ "${NETWORK,,}" == "user"* ]] && return 0

  ip link set "$VM_NET_TAP" down promisc off &> null || true
  ip link delete "$VM_NET_TAP" &> null || true

  ip link set dockerbridge down &> null || true
  ip link delete dockerbridge &> null || true

  return 0
}

closeNetwork() {

  if [[ "${WEB:-}" != [Nn]* && "$DHCP" == [Yy1]* ]]; then

    # Shutdown nginx
    nginx -s stop 2> /dev/null
    fWait "nginx"

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

checkOS() {

  local kernel
  local os=""
  local if="macvlan"
  kernel=$(uname -a)

  [[ "${kernel,,}" == *"darwin"* ]] && os="Docker Desktop for macOS"
  [[ "${kernel,,}" == *"microsoft"* ]] && os="Docker Desktop for Windows"

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

  NIC=$(ethtool -i "$VM_NET_DEV" | grep -m 1 -i 'driver:' | awk '{print $(2)}')

  if [[ "${NIC,,}" != "veth" ]]; then
    [[ "$DEBUG" == [Yy1]* ]] && info "Detected NIC: $NIC"
    error "This container does not support host mode networking!" && exit 29
  fi

  BASE_IP="${VM_NET_IP%.*}."

  if [ "${VM_NET_IP/$BASE_IP/}" -lt "3" ]; then
    error "Invalid VM_NET_IP, must end in a higher number than .3" && exit 27
  fi
  
  if [ -z "$MTU" ]; then
    MTU=$(cat "/sys/class/net/$VM_NET_DEV/mtu")
  fi

  if [ "$MTU" -gt "1500" ]; then
    info "MTU size is too large: $MTU, ignoring..." && MTU="0"
  fi

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

  GATEWAY=$(ip route list dev "$VM_NET_DEV" | awk ' /^default/ {print $3}' | head -n 1)
  IP=$(ip address show dev "$VM_NET_DEV" | grep inet | awk '/inet / { print $2 }' | cut -f1 -d/ | head -n 1)

  IP6=""
  # shellcheck disable=SC2143
  if [ -f /proc/net/if_inet6 ] && [ -n "$(ifconfig -a | grep inet6)" ]; then
    IP6=$(ip -6 addr show dev "$VM_NET_DEV" scope global up)
    [ -n "$IP6" ] && IP6=$(echo "$IP6" | sed -e's/^.*inet6 \([^ ]*\)\/.*$/\1/;t;d' | head -n 1)
  fi

  [ -f "/run/.containerenv" ] && PODMAN="Y" || PODMAN="N"
  echo "$IP" > /run/shm/qemu.ip

  return 0
}

# ######################################
#  Configure Network
# ######################################

if [[ "$NETWORK" == [Nn]* ]]; then
  NET_OPTS=""
  return 0
fi

getInfo
html "Initializing network..."

if [[ "$DEBUG" == [Yy1]* ]]; then
  mtu=$(cat "/sys/class/net/$VM_NET_DEV/mtu")
  line="Host: $HOST  IP: $IP  Gateway: $GATEWAY  Interface: $VM_NET_DEV  MAC: $VM_NET_MAC  MTU: $mtu"
  [[ "$MTU" != "0" && "$MTU" != "$mtu" ]] && line+=" ($MTU)"
  info "$line"
  if [ -f /etc/resolv.conf ]; then
    nameservers=$(grep '^nameserver*' /etc/resolv.conf | head -c -1 | sed 's/nameserver //g;' | sed -z 's/\n/, /g')
    [ -n "$nameservers" ] && info "Nameservers: $nameservers"
  fi
  echo
fi

if [[ "$IP" == "172.17."* ]]; then
  warn "your container IP starts with 172.17.* which will cause conflicts when you install the Container Manager package inside DSM!"
fi

if [[ -d "/sys/class/net/$VM_NET_TAP" ]]; then
  info "Lingering interface will be removed..."
  ip link delete "$VM_NET_TAP" || true
fi

if [[ "$DHCP" == [Yy1]* ]]; then

  checkOS

  if [[ "$IP" == "172."* ]]; then
    warn "container IP starts with 172.* which is often a sign that you are not on a macvlan network (required for DHCP)!"
  fi

  # Configure for macvtap interface
  configureDHCP || exit 20

  MSG="Booting DSM instance..."
  html "$MSG"

else

  if [[ "$IP" != "172."* && "$IP" != "10.8"* && "$IP" != "10.9"* ]]; then
    checkOS
  fi

  if [[ "${WEB:-}" != [Nn]* ]]; then

    # Shutdown nginx
    nginx -s stop 2> /dev/null
    fWait "nginx"

  fi

  if [[ "${NETWORK,,}" != "user"* ]]; then

    # Configure for tap interface
    if ! configureNAT; then

      closeBridge
      NETWORK="user"
      msg="falling back to user-mode networking!"
      if [[ "$PODMAN" != [Yy1]* ]]; then
        msg="an error occured, $msg"
      else
        msg="podman detected, $msg"
      fi
      warn "$msg"
      [ -z "$USER_PORTS" ] && info "Notice: when you want to expose ports in this mode, map them using this variable: \"USER_PORTS=5000,5001\"."

    fi

  fi

  if [[ "${NETWORK,,}" == "user"* ]]; then

    # Configure for user-mode networking (slirp)
    configureUser || exit 24

  fi

fi

NET_OPTS+=" -device $ADAPTER,id=net0,netdev=hostnet0,romfile=,mac=$VM_NET_MAC"
[[ "$MTU" != "0" && "$MTU" != "1500" ]] && NET_OPTS+=",host_mtu=$MTU"

return 0
