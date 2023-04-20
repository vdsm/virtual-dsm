#!/usr/bin/env bash
set -eu

# Docker environment variabeles

: ${VM_NET_HOST:='VirtualDSM'}
: ${VM_NET_MAC:='02:11:32:AA:BB:CC'}

: ${DNS_SERVERS:=''}
: ${DNSMASQ_OPTS:=''}
: ${DNSMASQ:='/usr/sbin/dnsmasq'}
: ${DNSMASQ_CONF_DIR:='/etc/dnsmasq.d'}

# ######################################
#  Functions
# ######################################

configureDHCP() {

  # Create /dev/vhost-net
  if [ ! -c /dev/vhost-net ]; then
    [ ! -d /dev/vhost-net ] && mkdir -m 755 /dev/vhost-net
    mknod /dev/vhost-net c 10 238
    chmod 666 /dev/vhost-net
  fi

  [ ! -c /dev/vhost-net ] && echo "Error: VHOST interface not available..." && exit 85

  VM_NET_TAP="_VmMacvtap"
  echo "Info: Retrieving IP via DHCP using MAC ${VM_NET_MAC}..."

  ip l add link eth0 name ${VM_NET_TAP} address ${VM_NET_MAC} type macvtap mode bridge || true
  ip l set ${VM_NET_TAP} up

  ip a flush eth0
  ip a flush ${VM_NET_TAP}

  DHCP_IP=$( dhclient -v ${VM_NET_TAP} 2>&1 | grep ^bound | cut -d' ' -f3 )

  if [[ "${DHCP_IP}" == [0-9.]* ]]; then
    echo "Info: Retrieved IP ${DHCP_IP} via DHCP"
  else
    echo "ERROR: Cannot retrieve IP from DHCP using MAC ${VM_NET_MAC}" && exit 16
  fi

  ip a flush ${VM_NET_TAP}

  TAP_PATH="/dev/tap$(</sys/class/net/${VM_NET_TAP}/ifindex)"

  # create dev file (there is no udev in container: need to be done manually)
  IFS=: read MAJOR MINOR < <(cat /sys/devices/virtual/net/${VM_NET_TAP}/tap*/dev)

  if (( MAJOR < 1)); then
     echo "ERROR: Cannot find: sys/devices/virtual/net/${VM_NET_TAP}" && exit 18
  fi

  [[ ! -e ${TAP_PATH} ]] && [[ -e /dev0/${TAP_PATH##*/} ]] && ln -s /dev0/${TAP_PATH##*/} ${TAP_PATH}

  if [[ ! -e ${TAP_PATH} ]]; then
    if ! mknod ${TAP_PATH} c $MAJOR $MINOR ; then
      echo "ERROR: Cannot mknod: ${TAP_PATH}" && exit 20
    fi
  fi

  if ! exec 30>>$TAP_PATH; then
    echo "ERROR: Please add the following docker variable to your container: --device-cgroup-rule='c ${MAJOR}:* rwm'" && exit 21
  fi

  if ! exec 40>>/dev/vhost-net; then
    echo "ERROR: Cannot find vhost!" && exit 22 
  fi

  NET_OPTS="-netdev tap,id=hostnet0,vhost=on,vhostfd=40,fd=30"
}

configureNAT () {

  VM_NET_IP='20.20.20.21'
  VM_NET_TAP="_VmNatTap"

  #Create bridge with static IP for the VM guest
  brctl addbr dockerbridge
  ip addr add ${VM_NET_IP%.*}.1/24 broadcast ${VM_NET_IP%.*}.255 dev dockerbridge
  ip link set dockerbridge up
  #QEMU Works with taps, set tap to the bridge created
  ip tuntap add dev ${VM_NET_TAP} mode tap
  ip link set ${VM_NET_TAP} up promisc on
  brctl addif dockerbridge ${VM_NET_TAP}

  #Add internet connection to the VM
  iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
  iptables -t nat -A PREROUTING -i eth0 -p tcp  -j DNAT --to $VM_NET_IP
  iptables -t nat -A PREROUTING -i eth0 -p udp  -j DNAT --to $VM_NET_IP

  # Hack for guest VMs complaining about "bad udp checksums in 5 packets"
  iptables -A POSTROUTING -t mangle -p udp --dport bootpc -j CHECKSUM --checksum-fill

  #Enable port forwarding flag
  [[ $(< /proc/sys/net/ipv4/ip_forward) -eq 0 ]] && sysctl -w net.ipv4.ip_forward=1

  # dnsmasq configuration:
  DNSMASQ_OPTS="$DNSMASQ_OPTS --dhcp-range=$VM_NET_IP,$VM_NET_IP --dhcp-host=$VM_NET_MAC,,$VM_NET_IP,$VM_NET_HOST,infinite --dhcp-option=option:netmask,255.255.255.0"

  # Create lease file for faster resolve
  echo "0 $VM_NET_MAC $VM_NET_IP $VM_NET_HOST 01:${VM_NET_MAC}" > /var/lib/misc/dnsmasq.leases
  chmod 644 /var/lib/misc/dnsmasq.leases

  NET_OPTS="-netdev tap,ifname=${VM_NET_TAP},script=no,downscript=no,id=hostnet0"

  # Build DNS options from container /etc/resolv.conf
  nameservers=($(grep '^nameserver' /etc/resolv.conf | sed 's/nameserver //'))
  searchdomains=$(grep '^search' /etc/resolv.conf | sed 's/search //' | sed 's/ /,/g')
  domainname=$(echo $searchdomains | awk -F"," '{print $1}')

  for nameserver in "${nameservers[@]}"; do
    if ! [[ $nameserver =~ .*:.* ]]; then
      [[ -z $DNS_SERVERS ]] && DNS_SERVERS=$nameserver || DNS_SERVERS="$DNS_SERVERS,$nameserver"
    fi
  done

  [[ -z $DNS_SERVERS ]] && DNS_SERVERS="1.1.1.1"

  DNSMASQ_OPTS="$DNSMASQ_OPTS --dhcp-option=option:dns-server,$DNS_SERVERS --dhcp-option=option:router,${VM_NET_IP%.*}.1"

  if [ -n "$searchdomains" -a "$searchdomains" != "." ]; then
    DNSMASQ_OPTS="$DNSMASQ_OPTS --dhcp-option=option:domain-search,$searchdomains --dhcp-option=option:domain-name,$domainname"
  else
    [[ -z $(hostname -d) ]] || DNSMASQ_OPTS="$DNSMASQ_OPTS --dhcp-option=option:domain-name,$(hostname -d)"
  fi

  [ "$DEBUG" = "Y" ] && echo && echo "$DNSMASQ $DNSMASQ_OPTS"

  $DNSMASQ $DNSMASQ_OPTS
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

if [ "$DEBUG" = "Y" ]; then

  IP=$(ip address show dev eth0 | grep inet | awk '/inet / { print $2 }' | cut -f1 -d/)
  echo "Info: Container IP: ${IP}" && echo

fi

update-alternatives --set iptables /usr/sbin/iptables-legacy > /dev/null
update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy > /dev/null

GATEWAY=$(ip r | grep default | awk '{print $3}')

#if [[ "$GATEWAY" == "172."* ]]; then
  # Configuration for static IP
  #configureNAT
#else
  # Configuration for DHCP IP
  configureDHCP
#fi

NET_OPTS="${NET_OPTS} -device virtio-net-pci,romfile=,netdev=hostnet0,mac=${VM_NET_MAC},id=net0"
