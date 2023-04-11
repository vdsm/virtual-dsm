#!/usr/bin/env bash
set -eu

: ${VM_NET_TAP:=''}
: ${VM_NET_MAC:=''}
: ${VM_NET_IP:='20.20.20.21'}

: ${DNS_SERVERS:=''}
: ${DNSMASQ:='/usr/sbin/dnsmasq'}
: ${DNSMASQ_OPTS:=''}
: ${DNSMASQ_CONF_DIR:='/etc/dnsmasq.d'}

# ######################################
#  Functions
# ######################################

setupLocalDhcp () {
  IP="$2"
  MAC="$1"
  CIDR="24"
  HOSTNAME="VirtualDSM"
  # dnsmasq configuration:
  DNSMASQ_OPTS="$DNSMASQ_OPTS --dhcp-range=$IP,$IP --dhcp-host=$MAC,,$IP,$HOSTNAME,infinite --dhcp-option=option:netmask,255.255.255.0"
  # Create lease file for faster resolve
  echo "0 $MAC $IP $HOSTNAME 01:${MAC}" > /var/lib/misc/dnsmasq.leases
  chmod 644 /var/lib/misc/dnsmasq.leases
}

# Setup macvtap device to connect later the VM and setup a new macvlan device to connect the host machine to the network
configureNatNetworks () {

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

  setupLocalDhcp $VM_NET_MAC $VM_NET_IP
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
[ ! -d "$IMG" ] && echo "Storage folder (${IMG}) not found!" && exit 86

#If environment variabele not set fall back to file
if [ -z "$VM_NET_MAC" ]; then
  FILE="${IMG}/guest.mac"
  [ ! -f "$FILE" ] && echo "00:11:32:2C:A7:85" > "$FILE"
  VM_NET_MAC=$(cat "${FILE}")
fi

update-alternatives --set iptables /usr/sbin/iptables-legacy > /dev/null
update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy > /dev/null

VM_NET_TAP="_VmNatTap"
configureNatNetworks
KVM_NET_OPTS="-netdev tap,ifname=${VM_NET_TAP},script=no,downscript=no,id=hostnet0"

# Build DNS options from container /etc/resolv.conf
nameservers=($(grep '^nameserver' /etc/resolv.conf | sed 's/nameserver //'))
searchdomains=$(grep '^search' /etc/resolv.conf | sed 's/search //' | sed 's/ /,/g')
domainname=$(echo $searchdomains | awk -F"," '{print $1}')

for nameserver in "${nameservers[@]}"; do
  if ! [[ $nameserver =~ .*:.* ]]; then
    [[ -z $DNS_SERVERS ]] && DNS_SERVERS=$nameserver || DNS_SERVERS="$DNS_SERVERS,$nameserver"
  fi
done

DNSMASQ_OPTS="$DNSMASQ_OPTS \
  --dhcp-option=option:dns-server,$DNS_SERVERS \
  --dhcp-option=option:router,${VM_NET_IP%.*}.1 \
  --dhcp-option=option:domain-search,$searchdomains \
  --dhcp-option=option:domain-name,$domainname"

[[ -z $(hostname -d) ]] || DNSMASQ_OPTS="$DNSMASQ_OPTS --dhcp-option=option:domain-name,$(hostname -d)"

$DNSMASQ $DNSMASQ_OPTS

KVM_NET_OPTS="${KVM_NET_OPTS} -device virtio-net-pci,netdev=hostnet0,mac=${VM_NET_MAC},id=net0"

# Hack for guest VMs complaining about "bad udp checksums in 5 packets"
iptables -A POSTROUTING -t mangle -p udp --dport bootpc -j CHECKSUM --checksum-fill
