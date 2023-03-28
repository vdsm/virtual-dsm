#!/usr/bin/env bash

set -eu

if [ ! -f "/run/server.sh" ]; then
    echo "Script must run inside Docker container!"
    exit 1
fi

/run/server.sh 5000 "<HTML><BODY><H1><CENTER>Please wait while Synology is installing...</CENTER></H1></BODY></HTML>" > /dev/null &

IMG="/storage"

[ ! -f "$IMG/boot.img" ] && rm -f $IMG/system.img

if [ ! -f "$IMG/system.img" ]; then

    echo "Downloading Synology DSM from $URL..."

    TMP="$IMG/tmp"
    FILE="$TMP/dsm.pat"

    rm -rf $TMP
    mkdir -p $TMP

    wget $URL -O $FILE -q --show-progress

    echo "Extracting DSM boot image..."

    if { tar tf "$FILE"; } >/dev/null 2>&1; then
       tar xpf $FILE -C $TMP/.
    else
       export LD_LIBRARY_PATH="/run"
       /run/syno_extract_system_patch $FILE $TMP/.
       export LD_LIBRARY_PATH=""
    fi

    rm $FILE

    BOOT=$(find $TMP -name "*.bin.zip")
    BOOT=$(echo $BOOT | head -c -5)

    unzip -q $BOOT.zip -d $TMP
    rm $BOOT.zip

    echo "Extracting DSM system image..."

    HDA="$TMP/hda1"
    mv $HDA.tgz $HDA.xz
    unxz $HDA.xz
    mv $HDA $HDA.tar

    echo "Extracting DSM disk template..."

    SYSTEM="$TMP/temp.img"
    PLATE="/data/template.img"

    rm -f $PLATE
    unxz $PLATE.xz
    mv -f $PLATE $SYSTEM

    echo "Mounting disk template..."
    MOUNT="/mnt/tmp"

    rm -rf $MOUNT
    mkdir -p $MOUNT
    guestmount -a $SYSTEM -m /dev/sda1:/ --rw $MOUNT
    rm -rf $MOUNT/{,.[!.],..?}*

    echo -n "Installing system partition.."

    tar xpf $HDA.tar --absolute-names --checkpoint=.5000 -C $MOUNT/

    echo ""
    echo "Unmounting disk template..."

    rm $HDA.tar
    guestunmount $MOUNT
    rm -rf $MOUNT

    mv -f $BOOT $IMG/boot.img
    mv -f $SYSTEM $IMG/system.img

    rm -rf $TMP
fi

echo "Booting Synology DSM for Docker..."

FILE="$IMG/boot.img"
if [ ! -f "$FILE" ]; then
    echo "ERROR: Synology DSM boot-image does not exist ($FILE)"
    exit 2
fi

FILE="$IMG/system.img"
if [ ! -f "$FILE" ]; then
    echo "ERROR: Synology DSM system-image does not exist ($FILE)"
    exit 2
fi

FILE="$IMG/data.img"
if [ ! -f "$FILE" ]; then
    truncate -s $DISK_SIZE $FILE
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
udhcpd -I $DUMMY_DHCPD_IP -f $DHCPD_CONF_FILE 2>&1 &

# Start the Serial Emulator

HOST_SERIAL=$(/run/serial.sh)
GUEST_SERIAL=$(/run/serial.sh)

./run/serial.bin -cpu=1 \
		-vmmversion="2.6.1-12139" \
		-buildnumber=42962 \
		-vmmts="1679863686" \
		-cpu_arch string="VirtualDSM" \
		-guestsn="$GUEST_SERIAL" \
		-hostsn="$HOST_SERIAL" \
		-guestuuid="ba13a19a-c0c1-4fef-9346-915ed3b98341" > /dev/null 2>&1 &

# Stop the webserver
pkill -f server.sh

echo "Booting OS..."

# Configure QEMU for graceful shutdown

QEMU_MONPORT=7100
QEMU_POWERDOWN_TIMEOUT=30

_graceful_shutdown() {

  local COUNT=0
  local QEMU_MONPORT="${QEMU_MONPORT:-7100}"
  local QEMU_POWERDOWN_TIMEOUT="${QEMU_POWERDOWN_TIMEOUT:-120}"

  set +e
  echo "Trying to shut down the VM gracefully"
  echo 'system_powerdown' | nc -q 1 localhost ${QEMU_MONPORT}>/dev/null 2>&1
  echo ""
  while echo 'info version'|nc -q 1 localhost ${QEMU_MONPORT:-7100}>/dev/null 2>&1 && [ "${COUNT}" -lt "${QEMU_POWERDOWN_TIMEOUT}" ]; do
    let COUNT++
    echo "QEMU still running. Retrying... (${COUNT}/${QEMU_POWERDOWN_TIMEOUT})"
    sleep 1
  done

  if echo 'info version'|nc -q 1 localhost ${QEMU_MONPORT:-7100}>/dev/null 2>&1; then
    echo "Killing the VM"
    echo 'quit' | nc -q 1 localhost ${QEMU_MONPORT}>/dev/null 2>&1 || true
  fi
  echo "Exiting..."
}

trap _graceful_shutdown SIGINT SIGTERM SIGHUP

# And run the VM! A brief explaination of the options here:
# -accel=kvm: use KVM for this VM (much faster for our case).
# -nographic: disable SDL graphics.
# -serial mon:stdio: use "monitored stdio" as our serial output.
exec qemu-system-x86_64 -name Synology -m $RAM_SIZE -machine accel=kvm -cpu host -nographic -serial mon:stdio \
    -monitor telnet:localhost:${QEMU_MONPORT:-7100},server,nowait,nodelay \
    -device virtio-serial-pci,id=virtio-serial0,bus=pci.0,addr=0x3 -chardev pty,id=charserial0 \
    -device isa-serial,chardev=charserial0,id=serial0 -chardev socket,id=charchannel0,host=127.0.0.1,port=12345,reconnect=10 \
    -device virtserialport,bus=virtio-serial0.0,nr=1,chardev=charchannel0,id=channel0,name=vchannel \
    -device virtio-net,netdev=tap0 -netdev tap,id=tap0,ifname=Tap,script=$QEMU_IFUP,downscript=$QEMU_IFDOWN \
    -device virtio-scsi-pci,id=hw-synoboot,bus=pci.0,addr=0xa -drive file=$IMG/boot.img,if=none,id=drive-synoboot,format=raw,cache=none,aio=native,detect-zeroes=on \
    -device scsi-hd,bus=hw-synoboot.0,channel=0,scsi-id=0,lun=0,drive=drive-synoboot,id=synoboot0,bootindex=1 \
    -device virtio-scsi-pci,id=hw-synosys,bus=pci.0,addr=0xb -drive file=$IMG/system.img,if=none,id=drive-synosys,format=raw,cache=none,aio=native,detect-zeroes=on \
    -device scsi-hd,bus=hw-synosys.0,channel=0,scsi-id=0,lun=0,drive=drive-synosys,id=synosys0,bootindex=2 \
    -device virtio-scsi-pci,id=hw-userdata,bus=pci.0,addr=0xc -drive file=$IMG/data.img,if=none,id=drive-userdata,format=raw,cache=none,aio=native,detect-zeroes=on \
    -device scsi-hd,bus=hw-userdata.0,channel=0,scsi-id=0,lun=0,drive=drive-userdata,id=userdata0,bootindex=3 \
    -device piix3-usb-uhci,id=usb,bus=pci.0,addr=0x1.0x2 &

wait $!
