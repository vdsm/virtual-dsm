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

configureMacVlan () {

  VM_NET_TAP="_VmMacvtap"
  echo "Info: Retrieving IP via DHCP using MAC ${VM_NET_MAC}..."

  ip l add link eth0 name ${VM_NET_TAP} address ${VM_NET_MAC} type macvtap mode bridge || true
  ip l set ${VM_NET_TAP} up

  ip a flush eth0
  ip a flush ${VM_NET_TAP}

  dhclient -v ${VM_NET_TAP}
  _DhcpIP=$( dhclient -v ${VM_NET_TAP} 2>&1 | grep ^bound | cut -d' ' -f3 )
  [[ "${_DhcpIP}" == [0-9.]* ]] \
  && echo "Info: Retrieved IP: ${_DhcpIP} from DHCP with MAC: ${VM_NET_MAC}" \
  || ( echo "ERROR: Cannot retrieve IP from DHCP with MAC: ${VM_NET_MAC}" && exit 16 )

  ip a flush ${VM_NET_TAP}

  _tmpTapPath="/dev/tap$(</sys/class/net/${VM_NET_TAP}/ifindex)"
  # get MAJOR MINOR DEVNAME
  MAJOR=""
  eval "$(</sys/class/net/${VM_NET_TAP}/macvtap/${_tmpTapPath##*/}/uevent) _tmp=0"

  [[ "x${MAJOR}" != "x" ]] \
	  && echo "... PLEASE MAKE SURE, Docker run command line used: --device-cgroup-rule='c ${MAJOR}:* rwm'" \
      	  || ( echo "... macvtap creation issue: Cannot find: /sys/class/net/${VM_NET_TAP}/" && exit 18 )

  [[ ! -e ${_tmpTapPath} ]] && [[ -e /dev0/${_tmpTapPath##*/} ]] && ln -s /dev0/${_tmpTapPath##*/} ${_tmpTapPath}

  if [[ ! -e ${_tmpTapPath} ]]; then
	  echo "... file does not exist: ${_tmpTapPath}"
	  mknod ${_tmpTapPath} c $MAJOR $MINOR \
		  && echo "... File created with mknod: ${_tmpTapPath}" \
		  || ( echo "... Cannot mknod: ${_tmpTapPath}" && exit 20 )
  fi

  NET_OPTS="-netdev tap,id=hostnet0,vhost=on,vhostfd=40,fd=30 30<>${_tmpTapPath} 40<>/dev/vhost-net"
}

configureNatNetwork () {

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

  NET_OPTS="${NET_OPTS} -device virtio-net-pci,romfile=,netdev=hostnet0,mac=${VM_NET_MAC},id=net0"
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

  echo && ifconfig
  echo && ip route && echo
  echo "Container IP: ${IP}" && echo

fi

update-alternatives --set iptables /usr/sbin/iptables-legacy > /dev/null
update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy > /dev/null

GATEWAY=$(ip r | grep default | awk '{print $3}')

if [[ "$GATEWAY" == "172."* ]]; then
  # Configuration for bridge network
  configureNatNetwork
else
  # Configuration for macvlan network
  configureMacVlan
fi

# Hack for guest VMs complaining about "bad udp checksums in 5 packets"
iptables -A POSTROUTING -t mangle -p udp --dport bootpc -j CHECKSUM --checksum-fill
