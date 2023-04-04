#!/usr/bin/env bash
set -eu

: ${INFO:='N'}
: ${DEBUG:='N'}

: ${DNSMASQ:='/usr/sbin/dnsmasq'}
: ${DNSMASQ_OPTS:=''}
: ${DNSMASQ_CONF_DIR:='/etc/dnsmasq.d'}
: ${DNS_SERVERS:=''}

# # (VM_NET_IP: Dont need to change coz all is port forwarded)
# # (VM_NET_DHCP: It use MACVTAP which is not compatible with all configuration)

: ${VM_NET_TAP:=''}
: ${VM_NET_IP:='20.20.20.21'}
: ${VM_NET_MAC:='00:11:32:2C:A7:85'}
: ${VM_NET_DHCP:='N'}
: ${VM_ENABLE_VIRTIO:='Y'}

# ######################################
#  Functions
# ######################################

log () {
  case "$1" in
    WARNING | ERROR )
      echo "$1: ${@:2}"
      ;;
    INFO)
      if [[ "$INFO" == [Yy1]* ]]; then
          echo "$1: ${@:2}"
      fi
      ;;
    DEBUG)
      if [[ "$DEBUG" == [Yy1]* ]]; then
          echo "$1: ${@:2}"
      fi
      ;;
    *)
      echo "-- $@"
      ;;
  esac
}

setupLocalDhcp () {
  CIDR="24"
  MAC="$1"
  IP="$2"
  #HOSTNAME=$(hostname -s)
  HOSTNAME="VirtualDSM"
  # dnsmasq configuration:
  log "INFO" "DHCP configured to serve IP $IP/$CIDR via dockerbridge"
  DNSMASQ_OPTS="$DNSMASQ_OPTS --dhcp-range=$IP,$IP --dhcp-host=$MAC,,$IP,$HOSTNAME,infinite --dhcp-option=option:netmask,255.255.255.0"
  # Create lease File FOr faster resolve
  echo "0 $MAC $IP $HOSTNAME 01:${MAC}" > /var/lib/misc/dnsmasq.leases
  chmod 644 /var/lib/misc/dnsmasq.leases
}

# Setup macvtap device to connect later the VM and setup a new macvlan devide
# to connect the host machine to the network
configureNatNetworks () {

  #For now we define static MAC because DHCP is very slow if MAC change every VM Boot
  #Create bridge with static IP for the VM Guest(COnnection VM-Docker)
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

  #For now we define static MAC because DHCP is very slow if DHCP change every VM Boot
  setupLocalDhcp $VM_NET_MAC $VM_NET_IP
}

# ######################################
#  Configure Network
# ######################################

MAJOR=""
_DhcpIP=""

# Create the necessary file structure for /dev/net/tun
if [ ! -c /dev/net/tun ]; then
  [ ! -d /dev/net ] && mkdir -m 755 /dev/net
  mknod /dev/net/tun c 10 200
  chmod 666 /dev/net/tun
fi

[ ! -c /dev/net/tun ] && echo "Error: TUN network interface not available..." && exit 85

#log "INFO" "Little dirty trick ..."
update-alternatives --set iptables /usr/sbin/iptables-legacy > /dev/null
update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy > /dev/null

log "INFO" "Configuring network ..."
#DEFAULT_ROUTE=$(ip route | grep default | awk '{print $3}')

if [[ "x${VM_NET_TAP}" == "x" ]]; then
	if [[ "${VM_NET_DHCP}" == [Yy1]* ]]; then
		VM_NET_TAP="_VmMacvtap"
		log "INFO" "... to retrieve IP via DHCP through Macvtap (${VM_NET_TAP}) and MAC: ${VM_NET_MAC}"

		ip l add link eth0 name ${VM_NET_TAP} address ${VM_NET_MAC} type macvtap mode bridge || true
		ip l set ${VM_NET_TAP} up

		ip a flush eth0
		ip a flush ${VM_NET_TAP}

		_DhcpIP=$( dhclient -v ${VM_NET_TAP} 2>&1 | grep ^bound | cut -d' ' -f3 )
		[[ "${_DhcpIP}" == [0-9.]* ]] \
		&& log "INFO" "... Retrieve IP: ${_DhcpIP} from DHCP with MAC: ${VM_NET_MAC}" \
		|| ( log "ERROR" "... Cannot retrieve IP from DHCP with MAC: ${VM_NET_MAC}" && exit 16 )

		ip a flush ${VM_NET_TAP}

		_tmpTapPath="/dev/tap$(</sys/class/net/${VM_NET_TAP}/ifindex)"
		# get MAJOR MINOR DEVNAME
		MAJOR=""
		eval "$(</sys/class/net/${VM_NET_TAP}/macvtap/${_tmpTapPath##*/}/uevent) _tmp=0"

		[[ "x${MAJOR}" != "x" ]] \
			&& log "INFO" "... PLEASE MAKE SURE, Docker run command line used: --device-cgroup-rule='c ${MAJOR}:* rwm'" \
			|| ( log "ERROR" "... macvtap creation issue: Cannot find: /sys/class/net/${VM_NET_TAP}/" && exit 18 )

		[[ ! -e ${_tmpTapPath} ]] && [[ -e /dev0/${_tmpTapPath##*/} ]] && ln -s /dev0/${_tmpTapPath##*/} ${_tmpTapPath}

		if [[ ! -e ${_tmpTapPath} ]]; then
			log "WARNING" "... file does not exist: ${_tmpTapPath}"
			mknod ${_tmpTapPath} c $MAJOR $MINOR \
				&& log "INFO" "... File created with mknod: ${_tmpTapPath}" \
				|| ( log "ERROR" "... Cannot mknod: ${_tmpTapPath}" && exit 20 )
		fi
		KVM_NET_OPTS="-netdev tap,id=hostnet0,vhost=on,vhostfd=40,fd=30 30<>${_tmpTapPath} 40<>/dev/vhost-net"
	else
		VM_NET_TAP="_VmNatTap"
		log "INFO" "... NAT Network (${VM_NET_TAP}) to ${VM_NET_IP}"

		configureNatNetworks
		KVM_NET_OPTS="-netdev tap,ifname=${VM_NET_TAP},script=no,downscript=no,id=hostnet0"

		# Build DNS options from container /etc/resolv.conf
		nameservers=($(grep '^nameserver' /etc/resolv.conf | sed 's/nameserver //'))
		searchdomains=$(grep '^search' /etc/resolv.conf | sed 's/search //' | sed 's/ /,/g')
		domainname=$(echo $searchdomains | awk -F"," '{print $1}')

		for nameserver in "${nameservers[@]}"; do
		  if [[ $nameserver =~ .*:.* ]]; then
		    log "INFO" "Skipping IPv6 nameserver: $nameserver"
		  else
		    [[ -z $DNS_SERVERS ]] && DNS_SERVERS=$nameserver || DNS_SERVERS="$DNS_SERVERS,$nameserver"
		  fi
		done
		DNSMASQ_OPTS="$DNSMASQ_OPTS                         \
		  --dhcp-option=option:dns-server,$DNS_SERVERS      \
		  --dhcp-option=option:router,${VM_NET_IP%.*}.1         \
		  --dhcp-option=option:domain-search,$searchdomains \
		  --dhcp-option=option:domain-name,$domainname      \
		  "
		[[ -z $(hostname -d) ]] || DNSMASQ_OPTS="$DNSMASQ_OPTS --dhcp-option=option:domain-name,$(hostname -d)"

		log "INFO" "... Lauching dnsmasq"
		log "DEBUG" "dnsmasq options: $DNSMASQ_OPTS"
		$DNSMASQ $DNSMASQ_OPTS
	fi
else
	log "INFO" "... No configuration, just using tuntap : ${VM_NET_TAP}"
	KVM_NET_OPTS="-netdev tap,ifname=${VM_NET_TAP},script=no,downscript=no,id=hostnet0"
fi

#KVM_NET_OPTS="-netdev user,hostfwd=tcp:127.0.0.1:5000-:5000"
[[ "${VM_ENABLE_VIRTIO}" == [Yy1]* ]] \
	&& KVM_NET_OPTS="${KVM_NET_OPTS} -device virtio-net-pci,netdev=hostnet0,mac=${VM_NET_MAC},id=net0" \
	|| KVM_NET_OPTS="${KVM_NET_OPTS} -device e1000e,netdev=hostnet0,mac=${VM_NET_MAC},id=net0"

# Hack for guest VMs complaining about "bad udp checksums in 5 packets"
log "INFO" "Hack for guest VMs complaining about: bad udp checksums in 5 packets"
iptables -A POSTROUTING -t mangle -p udp --dport bootpc -j CHECKSUM --checksum-fill \
        || ( log "WARNING" "Iptables hack for checksum FAILED" && ethtool -K eth0 tx off || true )

[[ "x${MAJOR}" != "x" ]] && log "INFO" "PLEASE MAKE SURE, Docker is using the following option otherwise you may have permission issue on ${_tmpTapPath} file: --device-cgroup-rule='c ${MAJOR}:* rwm' "
[[ "${_DhcpIP}" == [0-9.]* ]] && log "INFO" "You should access your DSM with: http://${_DhcpIP}:5000"

log "INFO" "Done setting up network.."
