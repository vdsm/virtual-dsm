<h1 align="center">Virtual DSM for Docker
<br />
<p align="center">
<img src="https://github.com/kroese/virtual-dsm/raw/master/.github/screen.jpg" title="Screenshot" style="max-width:100%;" width="432" />
</p>

<div align="center">

[![build_img]][build_url]
[![gh_last_release_svg]][dsm-docker-hub]
[![Docker Image Size]][dsm-docker-hub]
[![Docker Pulls Count]][dsm-docker-hub]

[build_url]: https://github.com/kroese/virtual-dsm/actions
[dsm-docker-hub]: https://hub.docker.com/r/kroese/virtual-dsm

[build_img]: https://github.com/kroese/virtual-dsm/actions/workflows/build.yml/badge.svg
[Docker Image Size]: https://img.shields.io/docker/image-size/kroese/virtual-dsm/latest
[Docker Pulls Count]: https://img.shields.io/docker/pulls/kroese/virtual-dsm.svg?style=flat
[gh_last_release_svg]: https://img.shields.io/docker/v/kroese/virtual-dsm?arch=amd64&sort=date

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
        restart: on-failure
        stop_grace_period: 1m
```

Via `docker run`

```bash
docker run -it --rm -p 5000:5000 --device=/dev/kvm --cap-add NET_ADMIN --stop-timeout 60 kroese/virtual-dsm:latest
```

## FAQ

  * ### How do I change the size of the virtual disk? ###

    By default it is 16GB, but to increase it you can modify the `DISK_SIZE` setting in your compose file:

    ```
    environment:
      DISK_SIZE: "16G"
    ```

    To resize the disk to a capacity of 8 terabyte you would use a value of `"8T"` for example.

  * ### How do I change the location of the virtual disk? ###

    By default it resides inside a docker volume, but to store it somewhere else you can add these lines to your compose file:

    ```
    volumes:
      - /home/user/data:/storage
    ```

    Just replace `/home/user/data` with the path to the folder you want to use for storage.

  * ### How do I change the space reserved by the virtual disk? ###

    By default the total space for the disk is reserved in advance. If you want to only reserve the space that is actually used by the disk, add these lines:

    ```
    environment:
      ALLOCATE: "N"
    ```

    This might lower performance a bit, since the image file will need to grow every time new data is added to it.

  * ### How do I change the amount of CPU/RAM? ###

    By default a single core and 512MB of RAM is allocated to the container.

    To increase this you can add the following environment variables:

    ```
    environment:
      CPU_CORES: "4"
      RAM_SIZE: "2048M"
    ```

  * ### How do I check if my system supports KVM?

    To check if your system supports KVM run these commands:

    ```
    sudo apt install cpu-checker
    sudo kvm-ok
    ```

    If `kvm-ok` returns an error stating KVM acceleration cannot be used, you may need to change your BIOS settings.
    
  * ### How do I give the container its own IP address?

    By default the container uses bridge networking, and uses the same IP as the docker host. 

    If you want to give it a seperate IP address, create a macvlan network.

    For example:

    ```
    $ docker network create -d macvlan \
        --subnet=192.168.0.0/24 \
        --gateway=192.168.0.1 \
        --ip-range=192.168.0.100/28 \
        -o parent=eth0 vdsm
    ```
    Modify these values to match your local subnet. 

    Now change the containers configuration in your compose file:

    ```
    networks:
        vdsm:             
            ipv4_address: 192.168.0.100
    ```

    And add the network to the very bottom of your compose file:

    ```
    networks:
        vdsm:
            external: true
    ```

    This also has the advantage that you don't need to do any portmapping anymore, because all ports will be fully exposed this way.

    NOTE: You will not be able to reach this IP from the Docker host, as macvlan does not allow communication between those two. There are some ways to fix that if necessary, but they go beyond the scope of this FAQ.

  * ### How can the container get an IP address via DHCP? ###

    First follow the steps to configure the container for macvlan (see above), and then add the following lines to your compose file:

    ```
    environment:
        DHCP: "Y"
    devices:
        - /dev/vhost-net
    device_cgroup_rules:
        - 'c 510:* rwm'
    ```

    NOTE: The exact cgroup rule may be different than `510` depending on your system, but the correct rule number will be printed to the log output in case of error.

  * ### How do I install a specific version of vDSM? ###

    By default it installs vDSM 7.2, but if you want to use an older version you can add its URL to your compose file:

    ```
    environment:
      URL: "https://global.synologydownload.com/download/DSM/release/7.1.1/42962-1/DSM_VirtualDSM_42962.pat"
    ```

    You can also switch back and forth between versions this way without loosing your file data.

  * ### What are the differences compared to standard DSM? ###

    There are only three minor differences: the Virtual Machine Manager package is not available, Surveillance Station does not include any free licenses, and logging in to your Synology account is not supported.
 
## Acknowledgments

Based on an [article](https://jxcn.org/2022/04/vdsm-first-try/) by JXCN.

## Disclaimer

Only run this container on original Synology hardware, any other use is not permitted and might not be legal.
