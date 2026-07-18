# Environment Variables

This page lists all the environment variables that can be used to configure the container.

An empty default means the variable is unset and its value is determined automatically when applicable.

## 💽 Virtual DSM

| Variable | Default | Description |
|---|---|---|
| `URL` |  | URL or local path to the DSM `.pat` installation file. Downloads the default Virtual DSM image automatically when unset. |
| `COUNTRY` |  | Country code used to select the Synology download mirror. Detected automatically when unset. |
| `HOST_MAC` |  | MAC address reported to DSM. |
| `HOST_MODEL` |  | Synology host model reported to DSM. |
| `HOST_SERIAL` |  | Synology host serial number reported to DSM. |
| `GUEST_SERIAL` |  | Synology guest serial number reported to DSM. |

## 🧠 CPU and Memory

| Variable | Default | Description |
|---|---|---|
| `CPU_CORES` | `2` | Number of virtual CPU cores, such as `4`, `half`, or `max`. |
| `CPU_MODEL` | `host` | QEMU CPU model. |
| `CPU_FLAGS` |  | Additional QEMU CPU flags. |
| `HOST_CPU` |  | CPU name reported to DSM. Selected automatically when unset. |
| `KVM` | `Y` | Enables KVM hardware acceleration. |
| `RAM_SIZE` | `2G` | Amount of RAM assigned to DSM, such as `2G`, `4G`, `half`, or `max`. |
| `RAM_CHECK` | `Y` | Checks whether enough host memory is available before starting DSM. |

## 💾 Storage

| Variable | Default | Description |
|---|---|---|
| `DISK_SIZE` | `256G` | Size of the main data disk. |
| `DISK_FMT` | `raw` | Disk image format: `raw` or `qcow2`. |
| `DISK_TYPE` | `scsi` | Disk device type, such as `sata`, `scsi`, `nvme`, or `blk`. |
| `DISK_CACHE` | `none` | Disk cache mode, such as `none` or `writeback`. |
| `DISK_IO` | `native` | Disk I/O mode, such as `native`, `threads`, or `io_uring`. |
| `DISK_DISCARD` | `unmap` | Discard/TRIM mode for the primary disk. |
| `DISK_ROTATION` | `1` | Rotation rate reported to the guest. Use `1` to identify the disk as an SSD. |
| `DISK_FLAGS` |  | Additional options used when creating `qcow2` disks. |
| `ALLOCATE` | `N` | Preallocates space for the data disks. |
| `STORAGE` | `/storage` | Storage directory used for disks, settings, and downloads. |

## 🌐 Networking

| Variable | Default | Description |
|---|---|---|
| `NETWORK` |  | Network mode, such as `nat`, `user`, or `N` to disable networking. |
| `DHCP` | `N` | Enables macvtap networking so  DSM receives an address from the external LAN through DHCP. |
| `HOST` | `VirtualDSM` | Hostname assigned to DSM. |
| `IP` |  | Overrides the automatically selected guest IPv4 address. |
| `MAC` |  | Guest network adapter MAC address. |
| `ADAPTER` | `virtio-net-pci` | QEMU network adapter model. |
| `DEV` | `eth0` | Container network interface used as the uplink. |
| `MTU` |  | MTU assigned to the guest network interface. |
| `MASK` | `255.255.255.0` | IPv4 netmask. |
| `TAP` | `dsm` | TAP or macvtap interface name. |
| `BRIDGE` | `docker` | Bridge name used for NAT networking. |
| `HOST_PORTS` |  | Ports excluded from guest forwarding. |
| `USER_PORTS` |  | Additional ports to forward to DSM when using user-mode networking. |
| `DNSMASQ_OPTS` |  | Additional options passed to dnsmasq. |
| `DNSMASQ_DEBUG` | `N` | Enables dnsmasq debug output. |
| `DNSMASQ_DISABLE` | `N` | Disables the internal dnsmasq resolver. |
| `PASST_OPTS` |  | Additional options passed to passt. |
| `PASST_DEBUG` | `N` | Enables passt debug output. |

## 🖥️ Display

| Variable | Default | Description |
|---|---|---|
| `DISPLAY` | `none` | Display backend, such as `vnc`, `disabled`, or `none`. |
| `LOSSY` | `N` | Enables lossy VNC compression to reduce bandwidth usage. |
| `VGA` | `none` | QEMU video adapter model. |
| `GPU` | `N` | Enables Intel iGPU acceleration. |
| `RENDERNODE` | `/dev/dri/renderD128` | Render node used for GPU acceleration. |

## ⚙️ System

| Variable | Default | Description |
|---|---|---|
| `MACHINE` | `q35` | QEMU machine type. |
| `ARGUMENTS` |  | Additional raw arguments appended to the QEMU command line. |

## 🔌 Shutdown

| Variable | Default | Description |
|---|---|---|
| `SHUTDOWN` | `Y` | Enables graceful shutdown. |
| `TIMEOUT` | `115` | Maximum time, in seconds, to wait before forcing DSM to stop. |
| `API_TIMEOUT` | `90` | Maximum time, in seconds, to wait for the shutdown API call. |

## 🐞 Debugging

| Variable | Default | Description |
|---|---|---|
| `DEBUG` | `N` | Enables verbose debug output. |
| `TRACE` | `N` | Enables shell command tracing. |
| `HOST_DEBUG` | `N` | Enables debug output for the DSM host helper. |
