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

## Platforms

 - Linux x86-64

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
        cap_add:
            - NET_ADMIN
        devices:
            - /dev/kvm
            - /dev/net/tun
        ports:
            - 80:5000
            - 443:5001
            - 5000:5000
            - 5001:5001
        restart: on-failure
```

Via `docker run`:

```bash
$ docker run --rm -it \ 
    --name dsm \ 
    -e DISK_SIZE=16G \ 
    -e RAM_SIZE=512M \ 
    -p 80:5000 \ 
    -p 443:5001 \ 
    -p 5000:5000 \ 
    -p 5001:5001 \ 
    --cap-add NET_ADMIN \ 
    --device="/dev/kvm:/dev/kvm" \ 
    --device="/dev/net/tun:/dev/net/tun" \ 
    kroese/virtual-dsm:latest
```

## FAQ

  - How do I change the location of the virtual disk?

By default it resides inside a docker volume, but you can add these lines to your compose file:

```
volumes:
  - /home/user/data:/storage
```

to map `/storage` to any local folder you want to use. Just replace `/home/user/data` with the correct path.
