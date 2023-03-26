# virtual-dsm

[![Test](https://github.com/kroese/virtual-dsm/actions/workflows/test.yaml/badge.svg)](https://github.com/kroese/virtual-dsm/actions/workflows/test.yaml)

A docker container for running Synology's Virtual DSM.

Docker Hub: [kroese/virtual-dsm](https://hub.docker.com/r/kroese/virtual-dsm/)

## Using the container

Via `docker run`:

```bash
$ docker run --rm -it \
    --device=/dev/kvm:/dev/kvm \
    --device=/dev/net/tun:/dev/net/tun \
    --cap-add NET_ADMIN \
    -p 5000:5000 -p 5001:5001 \
    -v /home/user/images:/image \
    kroese/virtual-dsm:latest
```

Via `docker-compose.yml`:

```yaml
version: "3"
services:
    vm:
        image: kroese/virtual-dsm:latest
        cap_add:
            - NET_ADMIN
        devices:
            - /dev/kvm
            - /dev/net/tun
        ports:
            - 5000:5000
            - 5001:5001
        volumes:
            - /home/user/images:/image
        restart: always
```

## Prerequisites

In order to use the container, you need two images called `boot.img` and `sys.img` from Synology containing the Virtual DSM OS.

* a
* b
