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

##### Via Docker Compose:

```yaml
services:
  dsm:
    container_name: dsm
    image: vdsm/virtual-dsm
    environment:
      DISK_SIZE: "16G"
    devices:
      - /dev/kvm
      - /dev/net/tun
    cap_add:
      - NET_ADMIN
    ports:
      - 5000:5000
    volumes:
      - ./dsm:/storage
    restart: always
    stop_grace_period: 2m
```

##### Via Docker CLI:

```bash
docker run -it --rm --name dsm -p 5000:5000 --device=/dev/kvm --device=/dev/net/tun --cap-add NET_ADMIN -v ${PWD:-.}/dsm:/storage --stop-timeout 120 vdsm/virtual-dsm
```

##### Via Kubernetes:

```shell
kubectl apply -f https://raw.githubusercontent.com/vdsm/virtual-dsm/refs/heads/master/kubernetes.yml
```

##### Via Github Codespaces:

[`Click here to launch this container in the cloud!`](https://github.com/codespaces/new?skip_quickstart=true&machine=basicLinux32gb&repo=619260050&ref=master&devcontainer_path=.devcontainer.json)

## Compatibility ⚙️

| **Product**  | **Platform**   | |
|---|---|---|
| Docker Engine     | Linux      | ✅ |
| Docker Desktop    | Linux      | ❌ |
| Docker Desktop    | macOS      | ❌ |
| Docker Desktop    | Windows 11 | ✅ |
| Docker Desktop    | Windows 10 | ❌ |
| Github Codespaces | Cloud      | ✅ |

## FAQ 💬

### How do I use it?

  Very simple! These are the steps:
  
  - Start the container and connect to [port 5000](http://127.0.0.1:5000/) using your web browser.

  - Wait until DSM finishes its installation
 
  - Choose an username and password, and you will be taken to the desktop.
  
  Enjoy your brand new NAS, and don't forget to star this repo!

### How do I change the storage location?

  To change the storage location, include the following bind mount in your compose file:

  ```yaml
  volumes:
    - ./dsm:/storage
  ```

  Replace the example path `./dsm` with the desired storage folder or named volume.
 
### How do I change the size of the disk?

  To expand the default size of 16 GB, locate the `DISK_SIZE` setting in your compose file and modify it to your preferred capacity:

  ```yaml
  environment:
    DISK_SIZE: "128G"
  ```
  
> [!TIP]
> This can also be used to resize the existing disk to a larger capacity without any data loss.

### How do I create a growable disk?

  By default, the entire capacity of the disk will be reserved in advance.

  To create a growable disk that only allocates space that is actually used, add the following environment variable:

  ```yaml
  environment:
    DISK_FMT: "qcow2"
  ```

### How do I add multiple disks?

  To create additional disks, modify your compose file like this:
  
  ```yaml
  environment:
    DISK2_SIZE: "32G"
    DISK3_SIZE: "64G"
  volumes:
    - ./example2:/storage2
    - ./example3:/storage3
  ```

### How do I pass-through a disk?

   It is possible to pass-through a disk device directly, which can be useful when your host is a virtual machine, as it removes an extra layer and allows for easier management. For use with physical disks this method provides little advantage and is not recommended.
   
   You can add the virtual device to your compose file like this:

  ```yaml
  devices:
    - /dev/disk/by-uuid/12345-12345-12345-12345-12345:/disk2
  ```

  The device needs to be totally empty (without any partition table) otherwise DSM does not always format it into a volume.
  
  Make sure to bind the disk via its UUID (obtainable via `lsblk -o name,uuid`) instead of its name (`/dev/sdc`), to prevent ever binding the wrong disk when the drive letters happen to change. 
 
> [!CAUTION]
> Do NOT use this feature with the goal of sharing files from the host, they might all get lost without warning when DSM creates the volume.

### How do I change the amount of CPU or RAM?

  By default, the container will be allowed to use a maximum of 1 CPU core and 1 GB of RAM.

  If you want to adjust this, you can specify the desired amount using the following environment variables:

  ```yaml
  environment:
    RAM_SIZE: "4G"
    CPU_CORES: "4"
  ```

### How do I verify if my system supports KVM?

  Only Linux and Windows 11 support KVM virtualization, macOS and Windows 10 do not unfortunately.
  
  You can run the following commands in Linux to check your system:

  ```bash
  sudo apt install cpu-checker
  sudo kvm-ok
  ```

  If you receive an error from `kvm-ok` indicating that KVM cannot be used, please check whether:

  - the virtualization extensions (`Intel VT-x` or `AMD SVM`) are enabled in your BIOS.

  - you enabled "nested virtualization" if you are running the container inside a virtual machine.

  - you are not using a cloud provider, as most of them do not allow nested virtualization for their VPS's.

  If you do not receive any error from `kvm-ok` but the container still complains about KVM, please check whether:

  - you are not using "Docker Desktop for Linux" as it does not support KVM, instead make use of Docker Engine directly.
 
  - it could help to add `privileged: true` to your compose file (or `sudo` to your `docker run` command), to rule out any permission issue.

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

  After configuring the container for [macvlan](#how-do-i-assign-an-individual-ip-address-to-the-container), it is possible for DSM to become part of your home network by requesting an IP from your router, just like your other devices.

  To enable this mode, in which the container and DSM will have separate IP addresses, add the following lines to your compose file:

  ```yaml
  environment:
    DHCP: "Y"
  devices:
    - /dev/vhost-net
  device_cgroup_rules:
    - 'c *:* rwm'
  ```

### How do I pass-through the GPU?

  To pass-through your Intel GPU, add the following lines to your compose file:

  ```yaml
  environment:
    GPU: "Y"
  devices:
    - /dev/dri
  ```

> [!NOTE]
> This can be used to enable the facial recognition function in Synology Photos, but does not provide hardware transcoding for video.

### How do I install a specific version of vDSM?

  By default, version 7.2 will be installed, but if you prefer an older version, you can add the download URL of the `.pat` file to your compose file as follows:

  ```yaml
  environment:
    URL: "https://global.synologydownload.com/download/DSM/release/7.0.1/42218/DSM_VirtualDSM_42218.pat"
  ```

  With this method, it is even possible to switch back and forth between versions while keeping your file data intact.

  If you don't have internet access, it's also possible to skip the download by setting `URL` to:

  ```yaml
  environment:
    URL: "DSM_VirtualDSM_42218.pat"
  ```

  after placing a copy of [DSM_VirtualDSM_42218.pat](https://global.synologydownload.com/download/DSM/release/7.0.1/42218/DSM_VirtualDSM_42218.pat) in the root of your `/storage` folder.

### What are the differences compared to the standard DSM?

  There are only two minor differences: the Virtual Machine Manager package is not available, and Surveillance Station will not include any free licenses.

### How do I run Windows in a container?

  You can use [dockur/windows](https://github.com/dockur/windows) for that. It shares many of the same features, and even has completely automatic installation.

### How do I run a Linux desktop in a container?

  You can use [qemus/qemu](https://github.com/qemus/qemu) in that case.

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
[Package]: https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fipitio.github.io%2Fbackage%2Fvdsm%2Fvirtual-dsm%2Fvirtual-dsm.json&query=%24.downloads&logo=github&style=flat&color=066da5&label=pulls
