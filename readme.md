<h1 align="center">Virtual DSM<br />
<div align="center">
<a href="https://github.com/vdsm/virtual-dsm"><img src="https://github.com/vdsm/virtual-dsm/raw/master/.github/screen.jpg" title="Screenshot" style="max-width:100%;" width="432" /></a>
</div>
<div align="center">

[![Build]][build_url]
[![Version]][tag_url]
[![Size]][tag_url]
[![Package]][pkg_url]
[![Pulls]][hub_url]

</div></h1>

Virtual DSM in a Docker container.

## Features ✨

 - Multiple disks
 - KVM acceleration
 - Upgrades supported
 
## Usage  🐳

Via Docker Compose:

```yaml
services:
  dsm:
    container_name: dsm
    image: vdsm/virtual-dsm
    environment:
      DISK_SIZE: "16G"
    devices:
      - /dev/kvm
    cap_add:
      - NET_ADMIN
    ports:
      - 5000:5000
    volumes:
      - /var/dsm:/storage
    stop_grace_period: 2m
```

Via Docker CLI:

```bash
docker run -it --rm -p 5000:5000 --device=/dev/kvm --cap-add NET_ADMIN --stop-timeout 120 vdsm/virtual-dsm
```

Via Kubernetes:

```shell
kubectl apply -f kubernetes.yml
```

## FAQ 💬

### How do I use it?

  Very simple! These are the steps:
  
  - Start the container and connect to [port 5000](http://localhost:5000) using your web browser.

  - Wait until DSM is ready, choose an username and password, and you will be taken to the desktop.
  
  Enjoy your brand new machine, and don't forget to star this repo!

### How do I change the storage location?

  To change the storage location, include the following bind mount in your compose file:

  ```yaml
  volumes:
    - /var/dsm:/storage
  ```

  Replace the example path `/var/dsm` with the desired storage folder.
 
### How do I change the size of the disk?

  To expand the default size of 16 GB, locate the `DISK_SIZE` setting in your compose file and modify it to your preferred capacity:

  ```yaml
  environment:
    DISK_SIZE: "128G"
  ```
  
> [!TIP]
> This can also be used to resize the existing disk to a larger capacity without any data loss.

### How do I create a growable disk?

  By default, the entire capacity of the disk is reserved in advance.

  To create a growable disk that only allocates space that is actually used, add the following environment variable:

  ```yaml
  environment:
    DISK_FMT: "qcow2"
  ```

> [!NOTE]
> This may reduce the write performance of the disk.

### How do I add multiple disks?

  To create additional disks, modify your compose file like this:
  
  ```yaml
  environment:
    DISK2_SIZE: "32G"
    DISK3_SIZE: "64G"
  volumes:
    - /home/example:/storage2
    - /mnt/data/example:/storage3
  ```

### How do I pass-through a disk?

   It is possible to pass-through a disk device directly, by adding it to your compose file in this way:

  ```yaml
  devices:
    - /dev/disk/by-uuid/12345-12345-12345-12345-12345:/disk2
  ```

  Make sure to bind the disk via its UUID (obtainable via `lsblk -o name,uuid`) instead of its name (`/dev/sdc`), to prevent ever binding the wrong disk when the drive letters happen to change. 

> [!IMPORTANT]
> The device needs to be totally empty (without any partition table) otherwise DSM does not always format it into a volume.

> [!CAUTION]
> Do NOT use this feature with the goal of sharing files from the host, they will all be lost without warning when DSM creates the volume.

### How do I change the amount of CPU or RAM?

  By default, the container will be allowed to use a maximum of 1 CPU core and 1 GB of RAM.

  If you want to adjust this, you can specify the desired amount using the following environment variables:

  ```yaml
  environment:
    RAM_SIZE: "4G"
    CPU_CORES: "4"
  ```

### How do I verify if my system supports KVM?

  To verify that your system supports KVM, run the following commands:

  ```bash
  sudo apt install cpu-checker
  sudo kvm-ok
  ```

  If you receive an error from `kvm-ok` indicating that KVM acceleration can't be used, please check whether:

  - the virtualization extensions (`Intel VT-x` or `AMD SVM`) are enabled in your BIOS.

  - you are running an operating system that supports them, like Linux or Windows 11 (macOS and Windows 10 do not unfortunately).

  - you enabled "nested virtualization" if you are running the container inside a virtual machine.

  - you are not using a cloud provider, as most of them do not allow nested virtualization for their VPS's.

  If you didn't receive any error from `kvm-ok` at all, but the container still complains that `/dev/kvm` is missing, it might help to add `privileged: true` to your compose file (or `--privileged` to your `run` command), to rule out any permission issue.

### How do I assign an individual IP address to the container?

  By default, the container uses bridge networking, which shares the IP address with the host. 

  If you want to assign an individual IP address to the container, you can create a macvlan network as follows:

  ```bash
  docker network create -d macvlan \
      --subnet=192.168.0.0/24 \
      --gateway=192.168.0.1 \
      --ip-range=192.168.0.100/28 \
      -o parent=eth0 vdsm
  ```
  
  Be sure to modify these values to match your local subnet. 

  Once you have created the network, change your compose file to look as follows:

  ```yaml
  services:
    dsm:
      container_name: dsm
      ..<snip>..
      networks:
        vdsm:
          ipv4_address: 192.168.0.100

  networks:
    vdsm:
      external: true
  ```
 
  An added benefit of this approach is that you won't have to perform any port mapping anymore, since all ports will be exposed by default.

> [!IMPORTANT]
> This IP address won't be accessible from the Docker host due to the design of macvlan, which doesn't permit communication between the two. If this is a concern, you need to create a [second macvlan](https://blog.oddbit.com/post/2018-03-12-using-docker-macvlan-networks/#host-access) as a workaround.

### How can DSM acquire an IP address from my router?

  After configuring the container for macvlan (see above), it is possible for DSM to become part of your home network by requesting an IP from your router, just like your other devices.

  To enable this mode, add the following lines to your compose file:

  ```yaml
  environment:
    DHCP: "Y"
  devices:
    - /dev/vhost-net
  device_cgroup_rules:
    - 'c *:* rwm'
  ```

> [!NOTE]
> Even if you don't need DHCP, it's still recommended to enable this mode, as it prevents NAT issues and increases performance by using a `macvtap` interface. You can just set a static IP from the DSM control panel afterwards.

### How do I pass-through the GPU?

  To pass-through your Intel GPU, add the following lines to your compose file:

  ```yaml
  environment:
    GPU: "Y"
  devices:
    - /dev/dri
  ```

> [!TIP]
> This can be used to enable the facial recognition function in Synology Photos for example.

### How do I install a specific version of vDSM?

  By default, version 7.2 will be installed, but if you prefer an older version, you can add its download URL to your compose file as follows:

  ```yaml
  environment:
    URL: "https://global.synologydownload.com/download/DSM/release/7.0.1/42218/DSM_VirtualDSM_42218.pat"
  ```

  With this method, it is even possible to switch between different versions while keeping all your file data intact.

  If you don't have internet access, it's also possible to skip the download by setting URL to:

  ```yaml
  environment:
    URL: "DSM_VirtualDSM_42218.pat"
  ```

  after placing a file called `DSM_VirtualDSM_42218.pat` in your `/storage` folder.

### What are the differences compared to the standard DSM?

  There are only two minor differences: the Virtual Machine Manager package is not available, and Surveillance Station will not include any free licenses.
  
### Is this project legal?

  Yes, this project contains only open-source code and does not distribute any copyrighted material. Neither does it try to circumvent any copyright protection measures. So under all applicable laws, this project will be considered legal. 
  
  However, by installing Synology's Virtual DSM, you must accept their end-user license agreement, which does not permit installation on non-Synology hardware. So only run this container on an official Synology NAS, as any other use will be a violation of their terms and conditions.

## Stars 🌟
[![Stars](https://starchart.cc/vdsm/virtual-dsm.svg?variant=adaptive)](https://starchart.cc/vdsm/virtual-dsm)

## Disclaimer ⚖️

*Only run this container on Synology hardware, any other use is not permitted by their EULA. The product names, logos, brands, and other trademarks referred to within this project are the property of their respective trademark holders. This project is not affiliated, sponsored, or endorsed by Synology, Inc.*

[build_url]: https://github.com/vdsm/virtual-dsm/
[hub_url]: https://hub.docker.com/r/vdsm/virtual-dsm
[tag_url]: https://hub.docker.com/r/vdsm/virtual-dsm/tags
[pkg_url]: https://github.com/vdsm/virtual-dsm/pkgs/container/virtual-dsm

[Build]: https://github.com/vdsm/virtual-dsm/actions/workflows/build.yml/badge.svg
[Size]: https://img.shields.io/docker/image-size/vdsm/virtual-dsm/latest?color=066da5&label=size
[Pulls]: https://img.shields.io/docker/pulls/vdsm/virtual-dsm.svg?style=flat&label=pulls&logo=docker
[Version]: https://img.shields.io/docker/v/vdsm/virtual-dsm/latest?arch=amd64&sort=semver&color=066da5
[Package]: https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fraw.githubusercontent.com%2Fipitio%2Fghcr-pulls%2Fmaster%2Findex.json&query=%24%5B%3F(%40.owner%3D%3D%22vdsm%22%20%26%26%20%40.repo%3D%3D%22virtual-dsm%22%20%26%26%20%40.image%3D%3D%22virtual-dsm%22)%5D.pulls&logo=github&style=flat&color=066da5&label=pulls
