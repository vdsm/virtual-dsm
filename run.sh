#!/usr/bin/env bash
set -eu

/run/server.sh 5000 > /dev/null &

if /run/install.sh; then
  echo "Starting DSM for Docker..."
else
  echo "Installation failed (code $?)" && exit 80
fi

IMG="/storage"
BASE=$(basename "$URL" .pat)

FILE="$IMG/$BASE.boot.img"
[ ! -f "$FILE" ] && echo "ERROR: Virtual DSM boot-image does not exist ($FILE)" && exit 81

FILE="$IMG/$BASE.system.img"
[ ! -f "$FILE" ] && echo "ERROR: Virtual DSM system-image does not exist ($FILE)" && exit 82

FILE="$IMG/data$DISK_SIZE.img"
if [ ! -f "$FILE" ]; then
    truncate -s "$DISK_SIZE" "$FILE"
    mkfs.btrfs -q -L data -d single -m single "$FILE" > /dev/null
    #qemu-img convert -f raw -O qcow2 -o extended_l2=on,cluster_size=128k,compression_type=zstd,preallocation=metadata "$TMP" "$FILE"
fi

[ ! -f "$FILE" ] && echo "ERROR: Virtual DSM data-image does not exist ($FILE)" && exit 83

if ! /run/network.sh; then
  echo "Network setup failed (code $?)" && exit 84
fi

# Start the Serial Emulator

HOST_SERIAL=$(/run/serial.sh)
GUEST_SERIAL=$(/run/serial.sh)

./run/serial.bin -cpu=1 \
		-buildnumber=42962 \
		-vmmts="1679863686" \
		-hostsn="$HOST_SERIAL" \
		-guestsn="$GUEST_SERIAL" \
		-vmmversion="2.6.1-12139" \
		-cpu_arch="QEMU, Virtual CPU, X86_64" \
		-guestuuid="ba13a19a-c0c1-4fef-9346-915ed3b98341" > /dev/null 2>&1 &

# Stop the webserver
pkill -f server.sh

if [ -e /dev/kvm ] && sh -c 'echo -n > /dev/kvm' &> /dev/null; then
  echo "Booting DSM image..."
else
  echo "Error: KVM not available..." && exit 86
fi

# Configure QEMU for graceful shutdown

QEMU_MONPORT=7100
QEMU_POWERDOWN_TIMEOUT=30
QEMU_IFUP='/run/qemu-ifup'
QEMU_IFDOWN='/run/qemu-ifdown'

_graceful_shutdown() {

  local COUNT=0
  local QEMU_MONPORT="${QEMU_MONPORT:-7100}"
  local QEMU_POWERDOWN_TIMEOUT="${QEMU_POWERDOWN_TIMEOUT:-120}"

  set +e
  echo "Trying to shutdown gracefully.."

  # Send a NMI interrupt which will be detected by the agent
  echo 'nmi' | nc -q 1 localhost "${QEMU_MONPORT}">/dev/null 2>&1
  echo 'system_powerdown' | nc -q 1 localhost "${QEMU_MONPORT}">/dev/null 2>&1
  echo ""

  while echo 'info version'|nc -q 1 localhost "${QEMU_MONPORT:-7100}">/dev/null 2>&1 && [ "${COUNT}" -lt "${QEMU_POWERDOWN_TIMEOUT}" ]; do
    (( COUNT++ )) || true
    echo "Shutting down, waiting... (${COUNT}/${QEMU_POWERDOWN_TIMEOUT})"
    sleep 1
  done

  if echo 'info version'|nc -q 1 localhost "${QEMU_MONPORT:-7100}">/dev/null 2>&1; then
    echo "Killing the VM.."
    echo 'quit' | nc -q 1 localhost "${QEMU_MONPORT}">/dev/null 2>&1 || true
  fi

  echo "Exiting..."
}

trap _graceful_shutdown SIGINT SIGTERM SIGHUP

# And run the VM! A brief explaination of the options here:
# -accel=kvm: use KVM for this VM (much faster for our case).
# -nographic: disable SDL graphics.
# -serial mon:stdio: use "monitored stdio" as our serial output.

exec qemu-system-x86_64 -name Synology -m "$RAM_SIZE" -enable-kvm -machine accel=kvm,usb=off -cpu host -nographic \
    -serial mon:stdio \
    -monitor telnet:localhost:"${QEMU_MONPORT:-7100}",server,nowait,nodelay \
    -device virtio-balloon-pci,id=balloon0,bus=pci.0,addr=0x4 \
    -device virtio-serial-pci,id=virtio-serial0,bus=pci.0,addr=0x3 \
    -chardev pty,id=charserial0 \
    -device isa-serial,chardev=charserial0,id=serial0 \
    -chardev socket,id=charchannel0,host=127.0.0.1,port=12345,reconnect=10 \
    -device virtserialport,bus=virtio-serial0.0,nr=1,chardev=charchannel0,id=channel0,name=vchannel \
    -device virtio-net,netdev=tap0 -netdev tap,id=tap0,ifname=Tap,script="$QEMU_IFUP",downscript="$QEMU_IFDOWN" \
    -device virtio-scsi-pci,id=hw-synoboot,bus=pci.0,addr=0xa \
    -drive file="$IMG"/"$BASE".boot.img,if=none,id=drive-synoboot,format=raw,cache=none,aio=native,detect-zeroes=on \
    -device scsi-hd,bus=hw-synoboot.0,channel=0,scsi-id=0,lun=0,drive=drive-synoboot,id=synoboot0,bootindex=1 \
    -device virtio-scsi-pci,id=hw-synosys,bus=pci.0,addr=0xb \
    -drive file="$IMG"/"$BASE".system.img,if=none,id=drive-synosys,format=raw,cache=none,aio=native,detect-zeroes=on \
    -device scsi-hd,bus=hw-synosys.0,channel=0,scsi-id=0,lun=0,drive=drive-synosys,id=synosys0,bootindex=2 \
    -device virtio-scsi-pci,id=hw-userdata,bus=pci.0,addr=0xc \
    -drive file="$IMG"/data"$DISK_SIZE".img,if=none,id=drive-userdata,format=raw,cache=none,aio=native,detect-zeroes=on \
    -device scsi-hd,bus=hw-userdata.0,channel=0,scsi-id=0,lun=0,drive=drive-userdata,id=userdata0,bootindex=3 &

wait $!
