#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables

: ${DHCP:='N'}
: ${MAC:='02:11:32:AA:BB:CC'}

: ${VM_NET_TAP:='dsm'}
: ${VM_NET_DEV:='eth0'}
: ${VM_NET_MAC:="$MAC"}
: ${VM_NET_HOST:='VirtualDSM'}

: ${DNS_SERVERS:=''}
: ${DNSMASQ_OPTS:=''}
: ${DNSMASQ:='/usr/sbin/dnsmasq'}
: ${DNSMASQ_CONF_DIR:='/etc/dnsmasq.d'}

# ######################################
#  Functions
# ######################################

configureDHCP() {

  # Create a macvtap network for the VM guest

  { ip link add link "${VM_NET_DEV}" name "${VM_NET_TAP}" address "${VM_NET_MAC}" type macvtap mode bridge ; rc=$?; } || :

  if (( rc != 0 )); then
    error "Cannot create macvtap interface. Please make sure the network type is 'macvlan' and not 'ipvlan',"
    error "and that the NET_ADMIN capability has been added to the container config: --cap-add NET_ADMIN" && exit 16
  fi

  while ! ip link set "${VM_NET_TAP}" up; do
    info "Waiting for address to become available..."
    sleep 2
  done

  TAP_NR=$(</sys/class/net/"${VM_NET_TAP}"/ifindex)
  TAP_PATH="/dev/tap${TAP_NR}"

  # Create dev file (there is no udev in container: need to be done manually)
  IFS=: read -r MAJOR MINOR < <(cat /sys/devices/virtual/net/"${VM_NET_TAP}"/tap*/dev)
  (( MAJOR < 1)) && error "Cannot find: sys/devices/virtual/net/${VM_NET_TAP}" && exit 18

  [[ ! -e "${TAP_PATH}" ]] && [[ -e "/dev0/${TAP_PATH##*/}" ]] && ln -s "/dev0/${TAP_PATH##*/}" "${TAP_PATH}"

  if [[ ! -e "${TAP_PATH}" ]]; then
    { mknod "${TAP_PATH}" c "$MAJOR" "$MINOR" ; rc=$?; } || :
    (( rc != 0 )) && error "Cannot mknod: ${TAP_PATH} ($rc)" && exit 20
  fi

  { exec 30>>"$TAP_PATH"; rc=$?; } 2>/dev/null || :

  if (( rc != 0 )); then
    error "Cannot create TAP interface ($rc). Please add the following docker settings to your "
    error "container: --device-cgroup-rule='c ${MAJOR}:* rwm' --device=/dev/vhost-net" && exit 21
  fi

  { exec 40>>/dev/vhost-net; rc=$?; } 2>/dev/null || :

  if (( rc != 0 )); then
    error "VHOST can not be found ($rc). Please add the following "
    error "docker setting to your container: --device=/dev/vhost-net" && exit 22
  fi

  NET_OPTS="-netdev tap,id=hostnet0,vhost=on,vhostfd=40,fd=30"

  return 0
}

configureDNS () {

  # dnsmasq configuration:
  DNSMASQ_OPTS="$DNSMASQ_OPTS --dhcp-range=$VM_NET_IP,$VM_NET_IP --dhcp-host=$VM_NET_MAC,,$VM_NET_IP,$VM_NET_HOST,infinite --dhcp-option=option:netmask,255.255.255.0"

  # Create lease file for faster resolve
  echo "0 $VM_NET_MAC $VM_NET_IP $VM_NET_HOST 01:${VM_NET_MAC}" > /var/lib/misc/dnsmasq.leases
  chmod 644 /var/lib/misc/dnsmasq.leases

  # Build DNS options from container /etc/resolv.conf

  if [[ "${DEBUG}" == [Yy1]* ]]; then
    echo "/etc/resolv.conf:" && echo && cat /etc/resolv.conf && echo
  fi

  mapfile -t nameservers < <( { grep '^nameserver' /etc/resolv.conf || true; } | sed 's/\t/ /g' | sed 's/nameserver //' | sed 's/ //g')
  searchdomains=$( { grep '^search' /etc/resolv.conf || true; } | sed 's/\t/ /g' | sed 's/search //' | sed 's/#.*//' | sed 's/\s*$//g' | sed 's/ /,/g')
  domainname=$(echo "$searchdomains" | awk -F"," '{print $1}')

  for nameserver in "${nameservers[@]}"; do
    nameserver=$(echo "$nameserver" | sed 's/#.*//' )
    if ! [[ "$nameserver" =~ .*:.* ]]; then
      [[ -z "$DNS_SERVERS" ]] && DNS_SERVERS="$nameserver" || DNS_SERVERS="$DNS_SERVERS,$nameserver"
    fi
  done

  [[ -z "$DNS_SERVERS" ]] && DNS_SERVERS="1.1.1.1"

  DNSMASQ_OPTS="$DNSMASQ_OPTS --dhcp-option=option:dns-server,$DNS_SERVERS --dhcp-option=option:router,${VM_NET_IP%.*}.1"

  if [ -n "$searchdomains" ] && [ "$searchdomains" != "." ]; then
    DNSMASQ_OPTS="$DNSMASQ_OPTS --dhcp-option=option:domain-search,$searchdomains --dhcp-option=option:domain-name,$domainname"
  else
    [[ -z $(hostname -d) ]] || DNSMASQ_OPTS="$DNSMASQ_OPTS --dhcp-option=option:domain-name,$(hostname -d)"
  fi

  DNSMASQ_OPTS=$(echo "$DNSMASQ_OPTS" | sed 's/\t/ /g' | tr -s ' ' | sed 's/^ *//')

  [[ "${DEBUG}" == [Yy1]* ]] && set -x
  $DNSMASQ ${DNSMASQ_OPTS:+ $DNSMASQ_OPTS}
  { set +x; } 2>/dev/null
  [[ "${DEBUG}" == [Yy1]* ]] && echo

  return 0
}

configureNAT () {

  # Create a bridge with a static IP for the VM guest

  VM_NET_IP='20.20.20.21'
  [[ "${DEBUG}" == [Yy1]* ]] && set -x

  { ip link add dev dockerbridge type bridge ; rc=$?; } || :

  if (( rc != 0 )); then
    error "Capability NET_ADMIN has not been set most likely. Please add the "
    error "following docker setting to your container: --cap-add NET_ADMIN" && exit 23
  fi

  ip address add ${VM_NET_IP%.*}.1/24 broadcast ${VM_NET_IP%.*}.255 dev dockerbridge

  while ! ip link set dockerbridge up; do
    info "Waiting for address to become available..."
    sleep 2
  done

  # QEMU Works with taps, set tap to the bridge created
  ip tuntap add dev "${VM_NET_TAP}" mode tap

  while ! ip link set "${VM_NET_TAP}" up promisc on; do
    info "Waiting for tap to become available..."
    sleep 2
  done

  ip link set dev "${VM_NET_TAP}" master dockerbridge

  # Add internet connection to the VM
  IP=$(ip address show dev "${VM_NET_DEV}" | grep inet | awk '/inet / { print $2 }' | cut -f1 -d/)

  iptables -t nat -A POSTROUTING -o "${VM_NET_DEV}" -j MASQUERADE
  iptables -t nat -A PREROUTING -i "${VM_NET_DEV}" -d "${IP}" -p tcp  -j DNAT --to $VM_NET_IP
  iptables -t nat -A PREROUTING -i "${VM_NET_DEV}" -d "${IP}" -p udp  -j DNAT --to $VM_NET_IP

  if (( KERNEL > 4 )); then
    # Hack for guest VMs complaining about "bad udp checksums in 5 packets"
    iptables -A POSTROUTING -t mangle -p udp --dport bootpc -j CHECKSUM --checksum-fill || true
  fi

  { set +x; } 2>/dev/null
  [[ "${DEBUG}" == [Yy1]* ]] && echo

  # Check port forwarding flag
  if [[ $(< /proc/sys/net/ipv4/ip_forward) -eq 0 ]]; then
    { sysctl -w net.ipv4.ip_forward=1 ; rc=$?; } || :
    if (( rc != 0 )); then
      error "Please add the following docker setting to your container: --sysctl net.ipv4.ip_forward=1" && exit 24
    fi
  fi

  NET_OPTS="-netdev tap,ifname=${VM_NET_TAP},script=no,downscript=no,id=hostnet0"

  { exec 40>>/dev/vhost-net; rc=$?; } 2>/dev/null || :
  (( rc == 0 )) && NET_OPTS="$NET_OPTS,vhost=on,vhostfd=40"

  configureDNS

  return 0
}

closeNetwork () {

  if [[ "${DHCP}" == [Yy1]* ]]; then

    ip link set "${VM_NET_TAP}" down || true
    ip link delete "${VM_NET_TAP}" || true

  else

    ip link set "${VM_NET_TAP}" down promisc off || true
    ip link delete "${VM_NET_TAP}" || true

    ip link set dockerbridge down || true
    ip link delete dockerbridge || true

  fi
}

# ######################################
#  Configure Network
# ######################################

{ pkill -f server.sh || true; } 2>/dev/null

# Create the necessary file structure for /dev/net/tun
if [ ! -c /dev/net/tun ]; then
  [ ! -d /dev/net ] && mkdir -m 755 /dev/net
  mknod /dev/net/tun c 10 200
  chmod 666 /dev/net/tun
fi

[ ! -c /dev/net/tun ] && error "TUN network interface not available..." && exit 85

# Create the necessary file structure for /dev/vhost-net
if [ ! -c /dev/vhost-net ]; then
  mknod /dev/vhost-net c 10 238
  chmod 660 /dev/vhost-net
fi

update-alternatives --set iptables /usr/sbin/iptables-legacy > /dev/null
update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy > /dev/null

VM_NET_MAC="${VM_NET_MAC//-/:}"
GATEWAY=$(ip r | grep default | awk '{print $3}')

if [[ "${DEBUG}" == [Yy1]* ]]; then

  IP=$(ip address show dev "${VM_NET_DEV}" | grep inet | awk '/inet / { print $2 }' | cut -f1 -d/)
  info "Container IP is ${IP} with gateway ${GATEWAY}" && echo

fi

if [[ "${DHCP}" == [Yy1]* ]]; then

  if [[ "$GATEWAY" == "172."* ]]; then
    if [[ "${DEBUG}" == [Yy1]* ]]; then
      info "Warning: Are you sure the container is on a macvlan network?"
    else
      error "You can only enable DHCP while the container is on a macvlan network!" && exit 86
    fi
  fi

  # Configuration for DHCP IP
  configureDHCP

  # Display IP on port 80 and 5000
  /run/server.sh 5000 /run/ip.sh &

else

  # Configuration for static IP
  configureNAT

fi

NET_OPTS="${NET_OPTS} -device virtio-net-pci,romfile=,netdev=hostnet0,mac=${VM_NET_MAC},id=net0"

return 0
