virtual-dsm
=============

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

A docker container of Virtual DSM v7.2

## Features

 - Upgrades supported
 - KVM acceleration (optional)
 - Runs on Linux/Windows/MacOS 

## Usage

Via `docker-compose.yml`:

```yaml
version: "3"
services:
    vm:
        container_name: dsm
        image: kroese/virtual-dsm:latest
        environment:
            DISK_SIZE: "16G"
            RAM_SIZE: "512M"
            CPU_CORES: "1"
        devices:
            - /dev/kvm
        cap_add:
            - NET_ADMIN                       
        ports:
            - 80:5000
            - 443:5001
            - 5000:5000
            - 5001:5001
        restart: on-failure
```

Via `docker run`:

```bash
$ docker run -p 5000:5000 --cap-add NET_ADMIN --device=/dev/kvm kroese/virtual-dsm:latest
```

## FAQ

  * ### How do I change the size of the virtual disk? ###

    By default it is 16GB, but you can modify the `DISK_SIZE` setting in your compose file:

    ```
    environment:
        DISK_SIZE: "16G"
    ```

    To create an empty disk with a maximum capacity of 8 terabyte you would use a value of `"8T"` for example.

  * ### How do I change the location of the virtual disk? ###

    By default it resides inside a docker volume, but you can add these lines to your compose file:

    ```
    volumes:
        - /home/user/data:/storage
    ```

    Just replace `/home/user/data` with the path to the folder you want to use for storage.

  * ### How do I install a specific version of vDSM? ###

    By default it installs vDSM 7.2, but if you want to use an older version you can add its URL to your compose file:

    ```
    environment:
       URL: "https://global.synologydownload.com/download/DSM/release/7.0.1/42218/DSM_VirtualDSM_42218.pat"
    ```

    You can also switch back and forth between versions this way without loosing your file data.

  * ### What are the differences compared to standard DSM? ###

    There are only two minor differences: the Virtual Machine Manager package is not available and Surveillance Station does not include any free licenses.
 
## Acknowledgments

Partly based on an [article](https://jxcn.org/2022/04/vdsm-first-try/) by JXCN.
