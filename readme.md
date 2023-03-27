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

## Using the container

Via `docker run`:

```bash
$ docker run --rm -it \
    -p 5000:5000 \
    --cap-add NET_ADMIN \
    --cap-add SYS_ADMIN \
    --device=/dev/kvm:/dev/kvm \
    --device=/dev/fuse:/dev/fuse \
    --device=/dev/net/tun:/dev/net/tun \    
    -v /home/user/images:/images \
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
            - SYS_ADMIN
        devices:
            - /dev/kvm
            - /dev/fuse
            - /dev/net/tun
        ports:
            - 5000:5000
        volumes:
            - /home/user/images:/images
        restart: always
```

