virtual-dsm
=============

[![build_img]][build_url]
[![gh_last_release_svg]][dsm-docker-hub]
[![Docker Image Size]][dsm-docker-hub]
[![Docker Pulls Count]][dsm-docker-hub]

[build_url]: https://github.com/kroese/virtual-dsm/actions
[build_img]: https://github.com/kroese/virtual-dsm/actions/workflows/build.yml/badge.svg

[dsm-docker-hub]: https://hub.docker.com/r/kroese/virtual-dsm
[Docker Image Size]: https://img.shields.io/docker/image-size/kroese/virtual-dsm/latest
[Docker Pulls Count]: https://img.shields.io/docker/pulls/kroese/virtual-dsm.svg?style=flat
[gh_last_release_svg]: https://img.shields.io/docker/v/kroese/virtual-dsm?arch=amd64&sort=date

A docker container of Synology DSM v7.2 

## Using the container

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
    --privileged \
    --cap-add NET_ADMIN \
    --device=/dev/kvm:/dev/kvm \
    --device=/dev/fuse:/dev/fuse \
    --device=/dev/net/tun:/dev/net/tun \    
    kroese/virtual-dsm:latest
```

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
            - /dev/fuse
            - /dev/net/tun
        ports:
            - 80:5000
            - 443:5001
            - 5000:5000
            - 5001:5001
        privileged: true            
        restart: on-failure
```
