#!/usr/bin/env bash
set -eu

# Docker environment variabeles

: ${VM_NET_TAP:='dsm'}
: ${VM_NET_DEV:='eth0'}
: ${VM_NET_HOST:='VirtualDSM'}
: ${VM_NET_MAC:='02:11:32:AA:BB:CC'}

: ${DHCP:='N'}
: ${DNS_SERVERS:=''}
: ${DNSMASQ_OPTS:=''}
: ${DNSMASQ:='/usr/sbin/dnsmasq'}
: ${DNSMASQ_CONF_DIR:='/etc/dnsmasq.d'}

# ######################################
#  Functions
# ######################################

configureDHCP() {

  VM_NET_VLAN="vlan"
  GATEWAY=$(ip r | grep default | awk '{print $3}')
  NETWORK=$(ip -o route | grep "${VM_NET_DEV}" | grep -v default | awk '{print $1}')
  IP=$(ip address show dev "${VM_NET_DEV}" | grep inet | awk '/inet / { print $2 }' | cut -f1 -d/)

  ip l add link "${VM_NET_DEV}" "${VM_NET_VLAN}" type macvlan mode bridge

  ip address add "${IP}" dev "${VM_NET_VLAN}"
  ip link set dev "${VM_NET_VLAN}" up

  ip route flush dev "${VM_NET_DEV}"
  ip route flush dev "${VM_NET_VLAN}"

  ip route add "${NETWORK}" dev "${VM_NET_VLAN}" metric 0
  ip route add default via "${GATEWAY}"

  echo "Info: Retrieving IP via DHCP using MAC ${VM_NET_MAC}..."

  ip l add link "${VM_NET_DEV}" name "${VM_NET_TAP}" address "${VM_NET_MAC}" type macvtap mode bridge || true
  ip l set "${VM_NET_TAP}" up

  ip a flush "${VM_NET_DEV}"
  ip a flush "${VM_NET_TAP}"

  DHCP_IP=$( dhclient -v "${VM_NET_TAP}" 2>&1 | grep ^bound | cut -d' ' -f3 )

  if [[ "${DHCP_IP}" == [0-9.]* ]]; then
    echo "Info: Retrieved IP ${DHCP_IP} via DHCP"
  else
    echo "ERROR: Cannot retrieve IP from DHCP using MAC ${VM_NET_MAC}" && exit 16
  fi

  ip a flush "${VM_NET_TAP}"

  # Create /dev/vhost-net
  if [ ! -c /dev/vhost-net ]; then
    mknod /dev/vhost-net c 10 238
    chmod 660 /dev/vhost-net
  fi

  if [ ! -c /dev/vhost-net ]; then
    echo -n "Error: VHOST interface not available. Please add the following "
    echo "docker variable to your container: --device=/dev/vhost-net" && exit 85
  fi

  TAP_NR=$(</sys/class/net/"${VM_NET_TAP}"/ifindex)
  TAP_PATH="/dev/tap${TAP_NR}"

  # Create dev file (there is no udev in container: need to be done manually)
  IFS=: read -r MAJOR MINOR < <(cat /sys/devices/virtual/net/"${VM_NET_TAP}"/tap*/dev)

  if (( MAJOR < 1)); then
     echo "ERROR: Cannot find: sys/devices/virtual/net/${VM_NET_TAP}" && exit 18
  fi

  [[ ! -e "${TAP_PATH}" ]] && [[ -e "/dev0/${TAP_PATH##*/}" ]] && ln -s "/dev0/${TAP_PATH##*/}" "${TAP_PATH}"

  if [[ ! -e "${TAP_PATH}" ]]; then
    if ! mknod "${TAP_PATH}" c "$MAJOR" "$MINOR" ; then
      echo "ERROR: Cannot mknod: ${TAP_PATH}" && exit 20
    fi
  fi

  if ! exec 30>>"$TAP_PATH"; then
    echo -n "ERROR: Please add the following docker variables to your container:  "
    echo "--device=/dev/vhost-net --device-cgroup-rule='c ${MAJOR}:* rwm'" && exit 21
  fi

  if ! exec 40>>/dev/vhost-net; then
    echo -n "ERROR: VHOST can not be found. Please add the following docker "
    echo "variable to your container: --device=/dev/vhost-net" && exit 22
  fi

  # Store IP for Docker healthcheck
  echo "${DHCP_IP}" > "/var/dsm.ip"

  NET_OPTS="-netdev tap,id=hostnet0,vhost=on,vhostfd=40,fd=30"
}

configureNAT () {

  VM_NET_IP='20.20.20.21'

  #Create bridge with static IP for the VM guest
  brctl addbr dockerbridge
  ip addr add ${VM_NET_IP%.*}.1/24 broadcast ${VM_NET_IP%.*}.255 dev dockerbridge
  ip link set dockerbridge up

  #QEMU Works with taps, set tap to the bridge created
  ip tuntap add dev "${VM_NET_TAP}" mode tap
  ip link set "${VM_NET_TAP}" up promisc on
  brctl addif dockerbridge "${VM_NET_TAP}"

  #Add internet connection to the VM
  iptables -t nat -A POSTROUTING -o "${VM_NET_DEV}" -j MASQUERADE
  iptables -t nat -A PREROUTING -i "${VM_NET_DEV}" -p tcp  -j DNAT --to $VM_NET_IP
  iptables -t nat -A PREROUTING -i "${VM_NET_DEV}" -p udp  -j DNAT --to $VM_NET_IP

  # Hack for guest VMs complaining about "bad udp checksums in 5 packets"
  iptables -A POSTROUTING -t mangle -p udp --dport bootpc -j CHECKSUM --checksum-fill || true

  #Enable port forwarding flag
  [[ $(< /proc/sys/net/ipv4/ip_forward) -eq 0 ]] && sysctl -w net.ipv4.ip_forward=1

  # dnsmasq configuration:
  DNSMASQ_OPTS="$DNSMASQ_OPTS --dhcp-range=$VM_NET_IP,$VM_NET_IP --dhcp-host=$VM_NET_MAC,,$VM_NET_IP,$VM_NET_HOST,infinite --dhcp-option=option:netmask,255.255.255.0"

  # Create lease file for faster resolve
  echo "0 $VM_NET_MAC $VM_NET_IP $VM_NET_HOST 01:${VM_NET_MAC}" > /var/lib/misc/dnsmasq.leases
  chmod 644 /var/lib/misc/dnsmasq.leases

  # Store IP for Docker healthcheck
  echo "${VM_NET_IP}" > "/var/dsm.ip"

  NET_OPTS="-netdev tap,ifname=${VM_NET_TAP},script=no,downscript=no,id=hostnet0"

  # Build DNS options from container /etc/resolv.conf
  mapfile -t nameservers < <(grep '^nameserver' /etc/resolv.conf | sed 's/nameserver //')
  searchdomains=$(grep '^search' /etc/resolv.conf | sed 's/search //' | sed 's/ /,/g')
  domainname=$(echo "$searchdomains" | awk -F"," '{print $1}')

  for nameserver in "${nameservers[@]}"; do
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

  [ "$DEBUG" = "Y" ] && echo && echo "$DNSMASQ $DNSMASQ_OPTS"

  $DNSMASQ ${DNSMASQ_OPTS:+ $DNSMASQ_OPTS} 
}

# ######################################
#  Configure Network
# ######################################

# Create the necessary file structure for /dev/net/tun
if [ ! -c /dev/net/tun ]; then
  [ ! -d /dev/net ] && mkdir -m 755 /dev/net
  mknod /dev/net/tun c 10 200
  chmod 666 /dev/net/tun
fi

[ ! -c /dev/net/tun ] && echo "Error: TUN network interface not available..." && exit 85

update-alternatives --set iptables /usr/sbin/iptables-legacy > /dev/null
update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy > /dev/null

GATEWAY=$(ip r | grep default | awk '{print $3}')

if [ "$DEBUG" = "Y" ]; then

  IP=$(ip address show dev "${VM_NET_DEV}" | grep inet | awk '/inet / { print $2 }' | cut -f1 -d/)
  echo "Info: Container IP is ${IP} with gateway ${GATEWAY}"
  ifconfig
  ip route

fi

if [ "$DHCP" != "Y" ]; then

  # Configuration for static IP
  configureNAT

else

  if [[ "$GATEWAY" == "172."* ]]; then
    echo -n "ERROR: You cannot enable DHCP while the container is "
    echo "in a bridge network, only on a macvlan network!" && exit 86
  fi

  # Configuration for DHCP IP
  configureDHCP

  # Display the received IP on port 5000
  HTML="The location of DSM is http://${DHCP_IP}:5000<script>\
        setTimeout(function(){ window.location.replace("http://${DHCP_IP}:5000"); }, 2000);</script>"

  /run/server.sh 5000 "${HTML}" > /dev/null &

fi

NET_OPTS="${NET_OPTS} -device virtio-net-pci,romfile=,netdev=hostnet0,mac=${VM_NET_MAC},id=net0"
