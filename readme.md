virtual-dsm
=============

[![Build Status]][builds]
[![Test]][test]
[![gh_last_release_svg]][gh_last_release_url]
[![Docker Pulls Count]][dsm-docker-hub]

[Build Status]: https://github.com/kroese/virtual-dsm/workflows/Build%20&%20deploy%20on%20git%20tag%20push/badge.svg
[builds]: https://github.com/kroese/virtual-dsm/actions?query=workflow%3A%22Build+%26+deploy+on+git+tag+push%22
[test]: https://github.com/kroese/virtual-dsm/actions/workflows/test.yaml/badge.svg

[gh_last_release_svg]: https://img.shields.io/github/v/release/kroese/virtual-dsm?sort=semver
[gh_last_release_url]: https://github.com/kroese/virtual-dsm/releases/latest

[Docker Pulls Count]: https://img.shields.io/docker/pulls/kroese/virtual-dsm.svg?style=flat
[dsm-docker-hub]: https://hub.docker.com/r/kroese/virtual-dsm

A docker container for running Synology's Virtual DSM.

## Prerequisites

In order to use the container, you need two images called `boot.img` and `sys.img` from Synology containing the Virtual DSM 7 OS. 

Place them in the `/home/user/images` folder. A third empty image, called `data.img` will be automaticly generated with a size of 16GB. If you need more space for your DSM instance, you can manually generate a larger file by running `truncate -s 100G data.img` on your host OS.

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

