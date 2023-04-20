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

log () {
  case "$1" in
    INFO | WARNING | ERROR )
      echo "$1: ${@:2}"
      ;;
    DEBUG)
      echo "$1: ${@:2}"
      ;;
    *)
      echo "-- $@"
      ;;
  esac
}

# ContainsElement: checks if first parameter is among the array given as second parameter
# returns 0 if the element is found in the list and 1 if not
# usage: containsElement $item $list

containsElement () {
  local e
  for e in "${@:2}"; do [[ "$e" == "$1" ]] && return 0; done
  return 1
}

# Generate random MAC address
genMAC () {
  hexchars="0123456789ABCDEF"
  end=$( for i in {1..8} ; do echo -n ${hexchars:$(( $RANDOM % 16 )):1} ; done | sed -e 's/\(..\)/:\1/g' )
  echo "FE:05$end"
}

# atoi: Returns the integer representation of an IP arg, passed in ascii
# dotted-decimal notation (x.x.x.x)
atoi() {
  IP=$1
  IPnum=0
  for (( i=0 ; i<4 ; ++i ))
  do
    ((IPnum+=${IP%%.*}*$((256**$((3-${i}))))))
    IP=${IP#*.}
  done
  echo $IPnum
}

# itoa: returns the dotted-decimal ascii form of an IP arg passed in integer
# format
itoa() {
  echo -n $(($(($(($((${1}/256))/256))/256))%256)).
  echo -n $(($(($((${1}/256))/256))%256)).
  echo -n $(($((${1}/256))%256)).
  echo $((${1}%256))
}

cidr2mask() {
  local i mask=""
  local full_octets=$(($1/8))
  local partial_octet=$(($1%8))

  for ((i=0;i<4;i+=1)); do
    if [ $i -lt $full_octets ]; then
      mask+=255
    elif [ $i -eq $full_octets ]; then
      mask+=$((256 - 2**(8-$partial_octet)))
    else
      mask+=0
    fi
    test $i -lt 3 && mask+=.
  done

  echo $mask
}

# Generates and returns a new IP and MASK in a superset (inmediate wider range)
# of the given IP/MASK
# usage: getNonConflictingIP IP MASK
# returns NEWIP MASK

getNonConflictingIP () {
    local IP="$1"
    local CIDR="$2"

    (( "newCIDR=$CIDR-1" )) || true

    local i=$(atoi $IP)
    (( "j=$i^(1<<(32-$CIDR))" )) || true
    local newIP=$(itoa j)

    echo $newIP $newCIDR
}

# generates unused, random names for macvlan or bridge devices
# usage: generateNetDevNames DEVICETYPE
#   DEVICETYPE must be either 'macvlan' or 'bridge'
# returns:
#   - bridgeXXXXXX if DEVICETYPE is 'bridge'
#   - macvlanXXXXXX, macvtapXXXXXX if DEVICETYPE is 'macvlan'

generateNetdevNames () {
  devicetype=$1

  local netdevinterfaces=($(ip link show | awk "/$devicetype/ { print \$2 }" | cut -d '@' -f 1 | tr -d :))
  local randomID=$(cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 6 | head -n 1)

  # check if the device already exists and regenerate the name if so
  while containsElement "$devicetype$randomID" "${netdevinterfaces[@]}"; do randomID=$(cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 6 | head -n 1); done

  echo "$randomID"
}

setupBridge () {

  set -x
  local iface="$1"
  local mode="$2"
  local deviceID=$(generateNetdevNames $mode)
  local bridgeName="$mode$deviceID"

  if [[ $mode == "bridge" ]]; then
    brctl addbr "$bridgeName"
    brctl addif "$bridgeName" "$iface"
  else # use macvlan devices by default
    vtapdev="macvtap${deviceID}"
    until $(ip link add link $iface name $vtapdev type macvtap mode bridge); do
      sleep 1
    done

    ip link set $vtapdev address "$MAC"
    ip link set $vtapdev up

    # create a macvlan device for the host
    ip link add link $iface name $bridgeName type macvlan mode bridge
    ip link set $bridgeName up

    # create dev file (there is no udev in container: need to be done manually)
    IFS=: read major minor < <(cat /sys/devices/virtual/net/$vtapdev/tap*/dev)
    mknod "/dev/$vtapdev" c $major $minor
  fi

  set +x
  # get a new IP for the guest machine in a broader network broadcast domain
  if ! [[ -z $IP ]]; then
    newIP=($(getNonConflictingIP $IP $CIDR))
    ip address del "$IP/$CIDR" dev "$iface"
    ip address add "${newIP[0]}/${newIP[1]}" dev "$bridgeName"
  fi

  ip link set dev "$bridgeName" up

  echo $deviceID
}

# Setup macvtap device to connect later the VM and setup a new macvlan devide
# to connect the host machine to the network

configureNetworks () {

  local IP
  local i=0
  local GATEWAY=$(ip r | grep default | awk '{print $3}')

  for iface in "${local_ifaces[@]}"; do

    IPs=$(ip address show dev $iface | grep inet | awk '/inet / { print $2 }' | cut -f1 -d/)
    IPs=($IPs)
    MAC=$(ip link show $iface | awk '/ether/ { print $2 }')
    log "DEBUG" "Container original MAC address: $MAC"

    # If the container has more than one IP configured in a given interface,
    # the user can select which one to use.
    # The SELECTED_NETWORK environment variable is used to select that IP.
    # This env variable must be in the form IP/MASK (e.g. 1.2.3.4/24).
    #
    # If this env variable is not set, the IP to be given to the VM is
    # the first in the list for that interface (default behaviour).

    SELECTED_NETWORK=""

    if ! [[ -z "$SELECTED_NETWORK" ]]; then
      local given_ip given_mask
      IFS=/ read given_ip given_mask <<< $SELECTED_NETWORK
      local given_addr=$(atoi $given_ip)
      local given_mask=$((0xffffffff << (32 - $given_mask) & 0xffffffff))
      local given_broadcast=$((given_addr | ~given_mask & 0xffffffff))
      local given_network=$((given_addr & given_mask))

      for configured_ip in "${IPs[@]}"; do
        local configured_ip=$(atoi $configured_ip)
        if [[ $configured_ip -gt $given_network && $configured_ip -lt $given_broadcast ]]; then
          IP=$(itoa $configured_ip)
          log "INFO" "SELECTED_NETWORK ($SELECTED_NETWORK) found with ip $IP in $iface interface."
        fi
      done
      [[ -z "$IP" ]] && log "WARNING" "SELECTED_NETWORK ($SELECTED_NETWORK) not found in $iface interface."
    else
      IP=${IPs[0]}
    fi

    local CIDR=$(ip address show dev $iface | awk "/inet $IP/ { print \$2 }" | cut -f2 -d/)

    # use container MAC address ($MAC) for tap device
    # and generate a new one for the local interface
    ip link set $iface down
    ip link set $iface address $(genMAC)
    ip link set $iface up

    # setup the macvtap devices for bridging the VM

    deviceID=($(setupBridge $iface "macvlan"))
    bridgeName="macvlan$deviceID"
    log "DEBUG" "bridgeName: $bridgeName"

    # get a file descriptor
    (( fd=$i+3 )) || true
    exec $fd>>/dev/macvtap$deviceID

    NET_OPTS="-netdev tap,id=net$i,vhost=on,fd=$fd"
    NET_OPTS="-device virtio-net-pci,netdev=net$i,mac=$MAC $NET_OPTS"

    (( i++ )) || true

  done
}

configureDHCP() {

  VM_NET_TAP="_VmMacvtap"
  echo "Info: Retrieving IP via DHCP using MAC ${VM_NET_MAC}..."

  ip l add link eth0 name ${VM_NET_TAP} address ${VM_NET_MAC} type macvtap mode bridge || true
  ip l set ${VM_NET_TAP} up

  ip a flush eth0
  ip a flush ${VM_NET_TAP}

  _DhcpIP=$( dhclient -v ${VM_NET_TAP} 2>&1 | grep ^bound | cut -d' ' -f3 )
  [[ "${_DhcpIP}" == [0-9.]* ]] \
  && echo "Info: Retrieved IP ${_DhcpIP} from DHCP using MAC ${VM_NET_MAC}" \
  || ( echo "ERROR: Cannot retrieve IP from DHCP using MAC ${VM_NET_MAC}" && exit 16 )

  ip a flush ${VM_NET_TAP}

  _tmpTapPath="/dev/tap$(</sys/class/net/${VM_NET_TAP}/ifindex)"

  # get MAJOR MINOR DEVNAME
  MAJOR=""
  eval "$(</sys/class/net/${VM_NET_TAP}/macvtap/${_tmpTapPath##*/}/uevent) _tmp=0"

  [[ "x${MAJOR}" != "x" ]] \
	  && echo "Info: Please make sure that the following docker setting is used: --device-cgroup-rule='c ${MAJOR}:* rwm'" \
      	  || ( echo "Info: Macvtap creation issue: Cannot find: /sys/class/net/${VM_NET_TAP}/" && exit 18 )

  [[ ! -e ${_tmpTapPath} ]] && [[ -e /dev0/${_tmpTapPath##*/} ]] && ln -s /dev0/${_tmpTapPath##*/} ${_tmpTapPath}

  if [[ ! -e ${_tmpTapPath} ]]; then
    mknod ${_tmpTapPath} c $MAJOR $MINOR && : || ("ERROR: Cannot mknod: ${_tmpTapPath}" && exit 20)
  fi

  NET_OPTS="-netdev tap,id=hostnet0,ifname=tap2,script=no,downscript=no"
  #NET_OPTS="-netdev tap,id=hostnet0,vhost=on,vhostfd=40,fd=30 30<>${_tmpTapPath} 40<>/dev/vhost-net"
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

  echo && ifconfig
  echo && ip route && echo
  echo "Container IP: ${IP}" && echo

fi

update-alternatives --set iptables /usr/sbin/iptables-legacy > /dev/null
update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy > /dev/null

GATEWAY=$(ip r | grep default | awk '{print $3}')

#if [[ "$GATEWAY" == "172."* ]]; then
  # Configuration for static IP
  #configureNAT
#else
  # Configuration for DHCP IP
  #configureDHCP
#fi

  # Get all interfaces:
  local_ifaces=($(ip link show | grep -v noop | grep state | grep -v LOOPBACK | awk '{print $2}' | tr -d : | sed 's/@.*$//'))
  local_bridges=($(brctl show | tail -n +2 | awk '{print $1}'))

  # Get non-bridge interfaces:
  for i in "${local_bridges[@]}"
  do
    local_ifaces=(${local_ifaces[@]//*$i*})
  done

DEFAULT_ROUTE=$(ip route | grep default | awk '{print $3}')

configureNetworks

  # Hack for guest VMs complaining about "bad udp checksums in 5 packets"
  /usr/sbin/iptables -A POSTROUTING -t mangle -p udp --dport bootpc -j CHECKSUM --checksum-fill

  # Build DNS options from container /etc/resolv.conf
  nameservers=($(grep nameserver /etc/resolv.conf | sed 's/nameserver //'))
  searchdomains=$(grep search /etc/resolv.conf | sed 's/search //' | sed 's/ /,/g')
  domainname=$(echo $searchdomains | awk -F"," '{print $1}')

  for nameserver in "${nameservers[@]}"; do
    [[ -z $DNS_SERVERS ]] && DNS_SERVERS=$nameserver || DNS_SERVERS="$DNS_SERVERS,$nameserver"
  done
  DNSMASQ_OPTS="$DNSMASQ_OPTS                         \
    --dhcp-option=option:dns-server,$DNS_SERVERS      \
    --dhcp-option=option:router,$DEFAULT_ROUTE        \
    --dhcp-option=option:domain-search,$searchdomains \
    --dhcp-option=option:domain-name,$domainname      \
    "
  [[ -z $(hostname -d) ]] || DNSMASQ_OPTS="$DNSMASQ_OPTS --dhcp-option=option:domain-name,$(hostname -d)"
  log "INFO" "Lauching dnsmasq"
  log "DEBUG" "dnsmasq options: $DNSMASQ_OPTS"

$DNSMASQ $DNSMASQ_OPTS

NET_OPTS="${NET_OPTS} -device virtio-net-pci,romfile=,netdev=hostnet0,mac=${VM_NET_MAC},id=net0"

