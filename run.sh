#!/usr/bin/env bash

FILE="/images/boot.img"
if [ ! -f "$FILE" ]; then
    echo "ERROR: Synology DSM boot-image does not exist ($FILE)"
    exit 2
fi

FILE="/images/system.img"
if [ ! -f "$FILE" ]; then
    echo "ERROR: Synology DSM system-image does not exist ($FILE)"
    exit 2
fi

FILE="/images/data.img"
if [ ! -f "$FILE" ]; then
    truncate -s 16G $FILE
fi

if [ ! -f "$FILE" ]; then
    echo "ERROR: Synology DSM data-image does not exist ($FILE)"
    exit 2
fi


# A bridge of this name will be created to host the TAP interface created for
# the VM
QEMU_BRIDGE='qemubr0'

# DHCPD must have an IP address to run, but that address doesn't have to
# be valid. This is the dummy address dhcpd is configured to use.
DUMMY_DHCPD_IP='10.0.0.1'

# These scripts configure/deconfigure the VM interface on the bridge.
QEMU_IFUP='/run/qemu-ifup'
QEMU_IFDOWN='/run/qemu-ifdown'

# The name of the dhcpd config file we make
DHCPD_CONF_FILE='dhcpd.conf'

function default_intf() {
    ip -json route show |
        jq -r '.[] | select(.dst == "default") | .dev'
}

# First step, we run the things that need to happen before we start mucking
# with the interfaces. We start by generating the DHCPD config file based
# on our current address/routes. We "steal" the container's IP, and lease
# it to the VM once it starts up.
/run/generate-dhcpd-conf $QEMU_BRIDGE > $DHCPD_CONF_FILE
default_dev=`default_intf`

# Now we start modifying the networking configuration. First we clear out
# the IP address of the default device (will also have the side-effect of
# removing the default route)
ip addr flush dev $default_dev

# Next, we create our bridge, and add our container interface to it.
ip link add $QEMU_BRIDGE type bridge
ip link set dev $default_dev master $QEMU_BRIDGE

# Then, we toggle the interface and the bridge to make sure everything is up
# and running.
ip link set dev $default_dev up
ip link set dev $QEMU_BRIDGE up

# Prevent error about missing file
touch /var/lib/misc/udhcpd.leases

# Finally, start our DHCPD server
udhcpd -I $DUMMY_DHCPD_IP -f $DHCPD_CONF_FILE &

# And run the VM! A brief explaination of the options here:
# -enable-kvm: Use KVM for this VM (much faster for our case).
# -nographic: disable SDL graphics.
# -serial mon:stdio: use "monitored stdio" as our serial output.
exec qemu-system-x86_64 -enable-kvm -nographic -serial mon:stdio \
    "$@" \
    -device virtio-net,netdev=tap0 -netdev tap,id=tap0,ifname=Tap,script=$QEMU_IFUP,downscript=$QEMU_IFDOWN \
    -device virtio-scsi-pci,id=hw-synoboot,bus=pci.0,addr=0xa -drive file=/images/boot.img,if=none,id=drive-synoboot,format=raw,cache=none,aio=native,detect-zeroes=on \
    -device scsi-hd,bus=hw-synoboot.0,channel=0,scsi-id=0,lun=0,drive=drive-synoboot,id=synoboot0,bootindex=1 \
    -device virtio-scsi-pci,id=hw-synosys,bus=pci.0,addr=0xb -drive file=/images/system.img,if=none,id=drive-synosys,format=raw,cache=none,aio=native,detect-zeroes=on \
    -device scsi-hd,bus=hw-synosys.0,channel=0,scsi-id=0,lun=0,drive=drive-synosys,id=synosys0,bootindex=2 \
    -device virtio-scsi-pci,id=hw-userdata,bus=pci.0,addr=0xc -drive file=/images/data.img,if=none,id=drive-userdata,format=raw,cache=none,aio=native,detect-zeroes=on \
    -device scsi-hd,bus=hw-userdata.0,channel=0,scsi-id=0,lun=0,drive=drive-userdata,id=userdata0,bootindex=3
