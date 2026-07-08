# Environment Variables

This page lists all the environment variables that can be used to configure the container.

## 💽 Virtual DSM

| Variable | Default | Description |
|---|---|---|
| `URL` |  | URL or local path of the DSM `.pat` installation file. When unset, the default Virtual DSM image is downloaded automatically. |
| `HOST_MAC` |  | MAC address reported to DSM. |
| `HOST_MODEL` |  | Synology host device model reported to DSM. |
| `HOST_SERIAL` |  | Synology host serial number reported to DSM. |
| `GUEST_SERIAL` |  | Synology guest serial number reported to DSM. |

## 🧠 CPU and Memory

| Variable | Default | Description |
|---|---|---|
| `CPU_CORES` | `2` | Number of CPU cores assigned to the VM. Can also be set to `max` or `half`. |
| `CPU_MODEL` | `host` | QEMU CPU model to use. |
| `CPU_FLAGS` |  | Additional QEMU CPU flags. |
| `HOST_CPU` |  | CPU name reported to DSM. Automatically selected when unset. |
| `KVM` | `Y` | Enables KVM hardware acceleration. Set to `N` to disable. |
| `RAM_SIZE` | `2G` | Amount of RAM assigned to the VM, for example `2G`, `4G`, `max`, or `half`. |
| `RAM_CHECK` | `Y` | Checks whether enough host memory is available before starting the VM. |

## 💾 Storage

| Variable | Default | Description |
|---|---|---|
| `DISK_SIZE` | `256G` | Size of the main data disk. |
| `DISK_FMT` | `raw` | Disk image format, usually `raw` or `qcow2`. |
| `DISK_TYPE` | `scsi` | Disk controller/device type, such as `sata`, `scsi`, `nvme`, or `blk`. |
| `DISK_CACHE` | `none` | QEMU disk cache mode, for example `none` or `writeback`. |
| `DISK_IO` | `native` | QEMU disk I/O mode, for example `native`, `threads`, or `io_uring`. |
| `DISK_DISCARD` | `unmap` | Enables TRIM/unmap support for the data disk. |
| `DISK_ROTATION` | `1` | Rotation rate reported to the guest. Use `1` for SSD-like storage. |
| `DISK_FLAGS` |  | Additional options used when creating qcow2 disks. |
| `ALLOCATE` | `N` | Preallocates disk space when creating the data disk. |
| `STORAGE` | `/storage` | Storage directory used for disks, firmware variables, and generated files. |

## 🌐 Networking

| Variable | Default | Description |
|---|---|---|
| `NETWORK` | `Y` | Network mode. Common values are `Y` for NAT, `passt`, `slirp`, or `N` to disable networking. |
| `DHCP` | `N` | Enables DHCP/macvtap mode so the VM receives an address from the external LAN. |
| `IP` |  | Guest IP address override. |
| `MAC` |  | Guest network adapter MAC address. |
| `HOST` | `Virtual DSM` | Hostname assigned to the VM. |
| `DEV` | `eth0` | Host/container network interface to use. |
| `MTU` |  | Network MTU to use for the guest interface. |
| `MASK` | `255.255.255.0` | IPv4 netmask. |
| `TAP` | `dsm` | TAP/macvtap interface name. |
| `BRIDGE` | `docker` | Bridge name used for NAT networking. |
| `ADAPTER` | `virtio-net-pci` | QEMU network adapter model. |
| `HOST_PORTS` |  | Ports reserved for services running on the host/container side. |
| `USER_PORTS` |  | Additional ports to forward to the VM when using user-mode networking. |
| `DNSMASQ_OPTS` |  | Additional dnsmasq options. |
| `DNSMASQ_DEBUG` | `N` | Enables dnsmasq log tailing. |
| `DNSMASQ_DISABLE` | `N` | Disables the internal dnsmasq resolver. |
| `PASST_OPTS` |  | Additional passt options. |
| `PASST_DEBUG` | `N` | Enables passt debug output. |

## 🖥️ Display

| Variable | Default | Description |
|---|---|---|
| `DISPLAY` | `none` | QEMU display backend. Common values are `vnc`, `disabled`, or `none`. |
| `VGA` | `none` | QEMU video adapter model. |
| `GPU` | `N` | Enables Intel iGPU acceleration. |
| `RENDERNODE` | `/dev/dri/renderD128` | Render node used for GPU acceleration. |

## 🔌 Shutdown

| Variable | Default | Description |
|---|---|---|
| `SHUTDOWN` | `Y` | Enables graceful shutdown. |
| `TIMEOUT` | `115` | Timeout used while waiting for DSM to shut down. |
| `API_TIMEOUT` | `90` | Timeout used for the shutdown API call. |

## 🐞 Debugging

| Variable | Default | Description |
|---|---|---|
| `DEBUG` | `N` | Enables verbose debug output. |
| `TRACE` | `N` | Enables shell command tracing. |
| `COM_PORT` | `2210` | Internal communication port used by the DSM host helper. |
| `CHR_PORT` | `12345` | Internal character device port used by the DSM host helper. |
| `HOST_DEBUG` | `N` | Enables debug output for the host helper. |
| `ARGUMENTS` |  | Additional raw QEMU arguments appended to the generated command line. |
