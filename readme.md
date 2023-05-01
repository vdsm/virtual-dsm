<h1 align="center">Virtual DSM for Docker
<br />
<p align="center">
<img src="https://github.com/kroese/virtual-dsm/raw/master/.github/screen.jpg" title="Screenshot" style="max-width:100%;" width="432" />
</p>

<div align="center">

[![Build]][build_url]
[![Version]][hub_url]
[![Size]][hub_url]
[![Pulls]][hub_url]

[build_url]: https://github.com/kroese/virtual-dsm/
[hub_url]: https://hub.docker.com/r/kroese/virtual-dsm

[Build]: https://github.com/kroese/virtual-dsm/actions/workflows/build.yml/badge.svg
[Size]: https://img.shields.io/docker/image-size/kroese/virtual-dsm/latest?color=066da5&label=size
[Pulls]: https://img.shields.io/docker/pulls/kroese/virtual-dsm.svg?style=flat&label=pulls
[Version]: https://img.shields.io/docker/v/kroese/virtual-dsm?arch=amd64&sort=date&color=066da5

</div></h1>
Virtual DSM in a docker container.

## Features

 - KVM acceleration
 - Graceful shutdown
 - Upgrades supported

## Usage

Via `docker-compose.yml`

```yaml
version: "3"
services:
    dsm:
        container_name: dsm
        image: kroese/virtual-dsm:latest
        environment:
            DISK_SIZE: "16G"
        devices:
            - /dev/kvm
        cap_add:
            - NET_ADMIN                       
        ports:
            - 5000:5000
        volumes:
            - /opt/dsm:/storage
        restart: on-failure
        stop_grace_period: 1m
```

Via `docker run`

```bash
docker run -it --rm -p 5000:5000 --device=/dev/kvm --cap-add NET_ADMIN --stop-timeout 60 kroese/virtual-dsm:latest
```

## FAQ

  * ### How do I change the size of the virtual disk?

    To expand the default size of 16 GB, locate the `DISK_SIZE` setting in your compose file and modify it to your preferred capacity:

    ```
    environment:
      DISK_SIZE: "16G"
    ```

  * ### How do I change the location of the virtual disk?

    To change the virtual disk's location from the default docker volume, include the following bind mount in your compose file and replace the path `/home/user/data` with the desired storage folder:

    ```
    volumes:
      - /home/user/data:/storage
    ```

  * ### How do I change the space reserved by the virtual disk? 

    By default, the entire disk space is reserved in advance. To reserve only the space actually used by the disk, add the following environment variable:

    ```
    environment:
      ALLOCATE: "N"
    ```

    Keep in mind that this doesn't affect any existing disks, and that it may impact performance as the image file will need to grow each time new data is added.

  * ### How do I increase the amount of CPU/RAM?

    By default, a single core and 512MB of RAM is allocated to the container. To increase this, add the following environment variables:

    ```
    environment:
      CPU_CORES: "4"
      RAM_SIZE: "2048M"
    ```

  * ### How do I verify if my system supports KVM?

    To verify if your system supports KVM, run the following commands:

    ```
    sudo apt install cpu-checker
    sudo kvm-ok
    ```

    If you receive an error from `kvm-ok` indicating that KVM acceleration can't be used, check your BIOS settings.

  * ### How do I assign an individual IP address to the container?

    By default, the container uses bridge networking which shares the IP address with the host. 

    If you want to assign an individual IP address to the container, you can create a macvlan network as follows:

    ```
    $ docker network create -d macvlan \
        --subnet=192.168.0.0/24 \
        --gateway=192.168.0.1 \
        --ip-range=192.168.0.100/28 \
        -o parent=eth0 vdsm
    ```
    
    Be sure to modify the values to match your local subnet. 

    Once you have created the network, modify the container's configuration in your compose file as follows:

    ```
    networks:
        vdsm:             
            ipv4_address: 192.168.0.100
    ```
    
    Finally, add the network to the bottom of your compose file:

    ```
    networks:
        vdsm:
            external: true
    ```
   
    An added benefit of this approach is that you won't have to perform any port mapping anymore, since all ports will be exposed by default.

    Please note that this IP address won't be accessible from the Docker host due to the design of macvlan, which doesn't permit communication between the two. If this is a concern, there are some workarounds available, but they go beyond the scope of this FAQ.

  * ### How can the container acquire an IP address via DHCP?

    After configuring the container for macvlan (see above), add the following lines to your compose file:

    ```
    environment:
        DHCP: "Y"
    devices:
        - /dev/vhost-net
    device_cgroup_rules:
        - 'c 510:* rwm'
    ```

    Please note that the exact `cgroup` rule number may vary depending on your system, but the log output will indicate the correct number in case of an error.

  * ### How do I install a specific version of vDSM?

    By default version 7.2 will be installed, but if you prefer an older version, you can add its URL to your compose file as follows:

    ```
    environment:
      URL: "https://global.synologydownload.com/download/DSM/release/7.1.1/42962-1/DSM_VirtualDSM_42962.pat"
    ```

    With this method, you are able to switch between different versions while keeping your file data.

  * ### What are the differences compared to standard DSM?

    There are only three minor differences: the Virtual Machine Manager package is not provided, Surveillance Station doesn't include any free licenses, and logging in to your Synology account is not supported.

## Disclaimer

Only run this container on Synology hardware, any other use is not permitted and might not be legal.
