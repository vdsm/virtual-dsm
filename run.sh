#!/usr/bin/env bash

set -eu

/run/server.sh 5000 "<HTML><BODY><H1><CENTER>Please wait while Synology is installing...</CENTER></H1></BODY></HTML>" > /dev/null &

[ ! -f "/images/boot.img" ] && rm -f /images/dsm.pat
[ ! -f "/images/system.img" ] && rm -f /images/dsm.pat

FILE="/images/dsm.pat"
if [ ! -f "$FILE" ]; then
    echo "Downloading Synology DSM..."

    BASE="https://global.synologydownload.com/download/DSM"
    PAT="$BASE/beta/7.2/64216/DSM_VirtualDSM_64216.pat"
    #PAT="$BASE/release/7.1.1/42962-1/DSM_VirtualDSM_42962.pat"
    #PAT="$BASE/release/7.0.1/42218/DSM_VirtualDSM_42218.pat"

    wget $PAT -O $FILE -q --show-progress

    echo "Extracting DSM boot image..."

    rm -rf /images/out
    mkdir -p /images/out

    if { tar tf "$FILE"; } >/dev/null 2>&1; then
       tar xf $FILE --checkpoint=.100 -C /images/out/.
    else
       export LD_LIBRARY_PATH="/run"
       /run/syno_extract_system_patch $FILE /images/out/.
       export LD_LIBRARY_PATH=""
    fi

    BOOT=$(find /images/out -name "*.bin.zip")
    BOOT=$(echo $BOOT | head -c -5)

    unzip -q $BOOT.zip -d /images/out
    rm $BOOT.zip

    echo "Extracting DSM system image..."

    HDA="/images/out/hda1"
    mv $HDA.tgz $HDA.xz
    unxz $HDA.xz
    mv $HDA $HDA.tar

    echo "Extracting DSM disk template..."

    TEMP="/images/temp.img"
    PLATE="/data/template.img"

    rm -f $PLATE
    unxz $PLATE.xz
    mv $PLATE $TEMP

    echo "Mounting disk template..."

    rm -rf /mnt/tmp
    mkdir -p /mnt/tmp
    guestmount -a $TEMP -m /dev/sda1:/ --rw /mnt/tmp

    echo "Preparing disk template..."

    rm -rf /mnt/tmp/{,.[!.],..?}*

    echo "Installing system partition..."

    tar -xf $HDA.tar --absolute-names --checkpoint=.100 -C /mnt/tmp/

    echo "Unmounting disk template..."

    rm $HDA.tar

    guestunmount /mnt/tmp
    rm -rf /mnt/tmp

    mv -f $BOOT /images/boot.img
    mv -f $TEMP /images/system.img

    rm -rf /images/out
fi

echo "Booting Synology DSM for Docker..."

FILE="/images/boot.img"
if [ ! -f "$FILE" ]; then
    echo "ERROR: Synology DSM boot-image does not exist ($FILE)"
    rm -f /images/dsm.pat
    exit 2
fi

FILE="/images/system.img"
if [ ! -f "$FILE" ]; then
    echo "ERROR: Synology DSM system-image does not exist ($FILE)"
    rm -f /images/dsm.pat
    exit 2
fi

FILE="/images/data.img"
if [ ! -f "$FILE" ]; then
    truncate -s 16G $FILE
    mkfs.ext4 -q $FILE
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

echo "Launching Synology Serial Emulator..."

# Start the Synology Serial Emulator
./run/serial.bin -cpu 1 \
                 -vmmversion "2.6.1-12139" \
                 -buildnumber 42962 \
                 -vmmts 1650802981032 \
                 -cpu_arch string "QEMU, Virtual CPU, X86_64" \
                 -guestsn "0000000000000" \
                 -hostsn "0000000000000" \
                 -guestuuid "ba13a19a-c0c1-4fef-9346-915ed3b98341" > /dev/null &

# Stop the webserver
pkill -f server.sh

echo "Booting OS..."

# And run the VM! A brief explaination of the options here:
# -enable-kvm: Use KVM for this VM (much faster for our case).
# -nographic: disable SDL graphics.
# -serial mon:stdio: use "monitored stdio" as our serial output.
exec qemu-system-x86_64 -name Synology -enable-kvm -nographic -serial mon:stdio \
    "$@" \
    -device virtio-serial-pci,id=virtio-serial0,bus=pci.0,addr=0x3 -chardev pty,id=charserial0 \
    -device isa-serial,chardev=charserial0,id=serial0 -chardev socket,id=charchannel0,host=127.0.0.1,port=12345,reconnect=10 \
    -device virtserialport,bus=virtio-serial0.0,nr=1,chardev=charchannel0,id=channel0,name=vchannel \
    -device virtio-net,netdev=tap0 -netdev tap,id=tap0,ifname=Tap,script=$QEMU_IFUP,downscript=$QEMU_IFDOWN \
    -device virtio-scsi-pci,id=hw-synoboot,bus=pci.0,addr=0xa -drive file=/images/boot.img,if=none,id=drive-synoboot,format=raw,cache=none,aio=native,detect-zeroes=on \
    -device scsi-hd,bus=hw-synoboot.0,channel=0,scsi-id=0,lun=0,drive=drive-synoboot,id=synoboot0,bootindex=1 \
    -device virtio-scsi-pci,id=hw-synosys,bus=pci.0,addr=0xb -drive file=/images/system.img,if=none,id=drive-synosys,format=raw,cache=none,aio=native,detect-zeroes=on \
    -device scsi-hd,bus=hw-synosys.0,channel=0,scsi-id=0,lun=0,drive=drive-synosys,id=synosys0,bootindex=2 \
    -device virtio-scsi-pci,id=hw-userdata,bus=pci.0,addr=0xc -drive file=/images/data.img,if=none,id=drive-userdata,format=raw,cache=none,aio=native,detect-zeroes=on \
    -device scsi-hd,bus=hw-userdata.0,channel=0,scsi-id=0,lun=0,drive=drive-userdata,id=userdata0,bootindex=3 \
    -device piix3-usb-uhci,id=usb,bus=pci.0,addr=0x1.0x2

