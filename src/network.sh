#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables

: "${MAC:=""}"
: "${DHCP:="N"}"
: "${NETWORK:="Y"}"
: "${HOST_PORTS:=""}"

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
  { ip link add link "$VM_NET_DEV" name "$VM_NET_TAP" address "$VM_NET_MAC" type macvtap mode bridge ; rc=$?; } || :

  if (( rc != 0 )); then
    error "Cannot create macvtap interface. Please make sure that the network type is 'macvlan' and not 'ipvlan',"
    error "that your kernel is recent (>4) and supports it, and that the container has the NET_ADMIN capability set." && exit 16
  fi

  while ! ip link set "$VM_NET_TAP" up; do
    info "Waiting for MAC address $VM_NET_MAC to become available..."
    sleep 2
  done

  local TAP_NR TAP_PATH MAJOR MINOR
  TAP_NR=$(</sys/class/net/"$VM_NET_TAP"/ifindex)
  TAP_PATH="/dev/tap${TAP_NR}"

  # Create dev file (there is no udev in container: need to be done manually)
  IFS=: read -r MAJOR MINOR < <(cat /sys/devices/virtual/net/"$VM_NET_TAP"/tap*/dev)
  (( MAJOR < 1)) && error "Cannot find: sys/devices/virtual/net/$VM_NET_TAP" && exit 18

  [[ ! -e "$TAP_PATH" ]] && [[ -e "/dev0/${TAP_PATH##*/}" ]] && ln -s "/dev0/${TAP_PATH##*/}" "$TAP_PATH"

  if [[ ! -e "$TAP_PATH" ]]; then
    { mknod "$TAP_PATH" c "$MAJOR" "$MINOR" ; rc=$?; } || :
    (( rc != 0 )) && error "Cannot mknod: $TAP_PATH ($rc)" && exit 20
  fi

  { exec 30>>"$TAP_PATH"; rc=$?; } 2>/dev/null || :

  if (( rc != 0 )); then
    error "Cannot create TAP interface ($rc). $ADD_ERR --device-cgroup-rule='c *:* rwm'" && exit 21
  fi

  { exec 40>>/dev/vhost-net; rc=$?; } 2>/dev/null || :

  if (( rc != 0 )); then
    error "VHOST can not be found ($rc). $ADD_ERR --device=/dev/vhost-net" && exit 22
  fi

  NET_OPTS="-netdev tap,id=hostnet0,vhost=on,vhostfd=40,fd=30"

  return 0
}

configureDNS() {

  # dnsmasq configuration:
  DNSMASQ_OPTS="$DNSMASQ_OPTS --dhcp-range=$VM_NET_IP,$VM_NET_IP --dhcp-host=$VM_NET_MAC,,$VM_NET_IP,$VM_NET_HOST,infinite --dhcp-option=option:netmask,255.255.255.0"

  # Create lease file for faster resolve
  echo "0 $VM_NET_MAC $VM_NET_IP $VM_NET_HOST 01:$VM_NET_MAC" > /var/lib/misc/dnsmasq.leases
  chmod 644 /var/lib/misc/dnsmasq.leases

  # Set DNS server and gateway
  DNSMASQ_OPTS="$DNSMASQ_OPTS --dhcp-option=option:dns-server,${VM_NET_IP%.*}.1 --dhcp-option=option:router,${VM_NET_IP%.*}.1"

  # Add DNS entry for container
  DNSMASQ_OPTS="$DNSMASQ_OPTS --address=/host.lan/${VM_NET_IP%.*}.1"

  DNSMASQ_OPTS=$(echo "$DNSMASQ_OPTS" | sed 's/\t/ /g' | tr -s ' ' | sed 's/^ *//')
  [[ "$DEBUG" == [Yy1]* ]] && set -x

  if ! $DNSMASQ ${DNSMASQ_OPTS:+ $DNSMASQ_OPTS}; then
    error "Failed to start dnsmasq, reason: $?" && exit 29
  fi
  { set +x; } 2>/dev/null
  [[ "$DEBUG" == [Yy1]* ]] && echo

  return 0
}

getPorts() {

  local list=$1

  [ -z "$list" ] && echo "" && return 0

  if [[ "$list" != *","* ]]; then
    echo " ! --dport $list"
  else
    echo " -m multiport ! --dports $list"
  fi

  return 0
}

configureNAT() {

  # Create the necessary file structure for /dev/net/tun
  if [ ! -c /dev/net/tun ]; then
    [ ! -d /dev/net ] && mkdir -m 755 /dev/net
    if mknod /dev/net/tun c 10 200; then
      chmod 666 /dev/net/tun
    fi
  fi

  if [ ! -c /dev/net/tun ]; then
    error "TUN device missing. $ADD_ERR --device /dev/net/tun --cap-add NET_ADMIN" && exit 25
  fi

  # Check port forwarding flag
  if [[ $(< /proc/sys/net/ipv4/ip_forward) -eq 0 ]]; then
    { sysctl -w net.ipv4.ip_forward=1 > /dev/null; rc=$?; } || :
    if (( rc != 0 )) || [[ $(< /proc/sys/net/ipv4/ip_forward) -eq 0 ]]; then
      error "IP forwarding is disabled. $ADD_ERR --sysctl net.ipv4.ip_forward=1" && exit 24
    fi
  fi

  local tables="The 'ip_tables' kernel module is not loaded. Try this command: sudo modprobe ip_tables iptable_nat"
  local tuntap="The 'tun' kernel module is not available. Try this command: 'sudo modprobe tun' or run the container with 'privileged: true'."

  # Create a bridge with a static IP for the VM guest

  { ip link add dev dockerbridge type bridge ; rc=$?; } || :

  if (( rc != 0 )); then
    error "Failed to create bridge. $ADD_ERR --cap-add NET_ADMIN" && exit 23
  fi

  ip address add "${VM_NET_IP%.*}.1/24" broadcast "${VM_NET_IP%.*}.255" dev dockerbridge

  while ! ip link set dockerbridge up; do
    info "Waiting for IP address to become available..."
    sleep 2
  done

  # QEMU Works with taps, set tap to the bridge created
  if ! ip tuntap add dev "$VM_NET_TAP" mode tap; then
    error "$tuntap" && exit 31
  fi

  while ! ip link set "$VM_NET_TAP" up promisc on; do
    info "Waiting for TAP to become available..."
    sleep 2
  done

  ip link set dev "$VM_NET_TAP" master dockerbridge

  # Add internet connection to the VM
  update-alternatives --set iptables /usr/sbin/iptables-legacy > /dev/null
  update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy > /dev/null

  exclude=$(getPorts "$HOST_PORTS")

  if ! iptables -t nat -A POSTROUTING -o "$VM_NET_DEV" -j MASQUERADE; then
    error "$tables" && exit 30
  fi

  # shellcheck disable=SC2086
  iptables -t nat -A PREROUTING -i "$VM_NET_DEV" -d "$IP" -p tcp${exclude} -j DNAT --to "$VM_NET_IP"
  iptables -t nat -A PREROUTING -i "$VM_NET_DEV" -d "$IP" -p udp  -j DNAT --to "$VM_NET_IP"

  if (( KERNEL > 4 )); then
    # Hack for guest VMs complaining about "bad udp checksums in 5 packets"
    iptables -A POSTROUTING -t mangle -p udp --dport bootpc -j CHECKSUM --checksum-fill > /dev/null 2>&1 || true
  fi

  NET_OPTS="-netdev tap,ifname=$VM_NET_TAP,script=no,downscript=no,id=hostnet0"

  if [ -c /dev/vhost-net ]; then
    { exec 40>>/dev/vhost-net; rc=$?; } 2>/dev/null || :
    (( rc == 0 )) && NET_OPTS="$NET_OPTS,vhost=on,vhostfd=40"
  fi

  configureDNS

  return 0
}

closeNetwork() {

  if [[ "$DHCP" == [Yy1]* ]]; then

    # Shutdown nginx
    nginx -s stop 2> /dev/null
    fWait "nginx"

  fi

  [[ "$NETWORK" != [Yy1]* ]] && return 0

  exec 30<&- || true
  exec 40<&- || true

  if [[ "$DHCP" == [Yy1]* ]]; then

    ip link set "$VM_NET_TAP" down || true
    ip link delete "$VM_NET_TAP" || true

  else

    local pid="/var/run/dnsmasq.pid"
    [ -s "$pid" ] && pKill "$(<"$pid")"

    ip link set "$VM_NET_TAP" down promisc off || true
    ip link delete "$VM_NET_TAP" || true

    ip link set dockerbridge down || true
    ip link delete dockerbridge || true

  fi

  return 0
}

checkOS() {

  local name
  local os=""
  name=$(uname -a)

  [[ "${name,,}" == *"darwin"* ]] && os="MacOS"
  [[ "${name,,}" == *"microsoft"* ]] && os="Windows"

  if [ -n "$os" ]; then
    error "You are using Docker Desktop for $os which does not support macvlan, please revert to bridge networking!"
    return 1
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
    error "$ADD_ERR -e \"VM_NET_DEV=NAME\" to specify another interface name." && exit 27
  fi

  if [ -z "$VM_NET_MAC" ]; then
    local file="$STORAGE/dsm.mac"
    [ -s "$file" ] && VM_NET_MAC=$(<"$file")
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

  GATEWAY=$(ip route list dev "$VM_NET_DEV" | awk ' /^default/ {print $3}')
  IP=$(ip address show dev "$VM_NET_DEV" | grep inet | awk '/inet / { print $2 }' | cut -f1 -d/)
  echo "$IP" > /run/shm/qemu.ip

  return 0
}

# ######################################
#  Configure Network
# ######################################

if [[ "$NETWORK" != [Yy1]* ]]; then
  NET_OPTS=""
  return 0
fi

getInfo
html "Initializing network..."

if [[ "$DEBUG" == [Yy1]* ]]; then
  info "Host: $HOST  IP: $IP  Gateway: $GATEWAY  Interface: $VM_NET_DEV  MAC: $VM_NET_MAC"
  [ -f /etc/resolv.conf ] && grep '^nameserver*' /etc/resolv.conf
  echo
fi

if [[ "$IP" == "172.17."* ]]; then
  warn "your container IP starts with 172.17.* which will cause conflicts when you install the Container Manager package inside DSM!"
fi

if [[ "$DHCP" == [Yy1]* ]]; then

  ! checkOS && [[ "$DEBUG" != [Yy1]* ]] && exit 19

  if [[ "$GATEWAY" == "172."* ]]; then
    warn "your gateway IP starts with 172.* which is often a sign that you are not on a macvlan network (required for DHCP)!"
  fi

  # Configuration for DHCP IP
  configureDHCP

  MSG="Booting DSM instance..."
  html "$MSG"

else

  if [[ "$GATEWAY" != "172."* ]] && [[ "$GATEWAY" != "10.8"* ]] && [[ "$GATEWAY" != "10.9"* ]]; then
    ! checkOS && [[ "$DEBUG" != [Yy1]* ]] && exit 19
  fi

  # Shutdown nginx
  nginx -s stop 2> /dev/null
  fWait "nginx"

  # Configuration for static IP
  configureNAT

fi

NET_OPTS="$NET_OPTS -device virtio-net-pci,romfile=,netdev=hostnet0,mac=$VM_NET_MAC,id=net0"

return 0
