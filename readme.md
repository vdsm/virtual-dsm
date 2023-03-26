# virtual-dsm

[![Test](https://github.com/joshkunz/qemu-docker/actions/workflows/test.yaml/badge.svg)](https://github.com/joshkunz/qemu-docker/actions/workflows/test.yaml)

This repository contains a Docker container for running Synology's Virtual DSM.

Docker Hub: [jkz0/qemu](https://hub.docker.com/r/jkz0/qemu)

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

## Tips 

* VM networking is configured via DHCP, make sure to enable DHCP in your
  VM image. VMs will use the IP address of the container.
* You can quit the VM (when attached to the container) by entering the special
  key sequence `C-a x`. Killing the docker container will also shut down the
  VM.

## Caveat Emptor

* Only x86\_64 supported new. PRs to support other architectures welcome,
  though I imagine 99% of use-cases will be x86\_64.
* VMs will not be able to resolve container-names on user-defined bridges.
  This is due to the way Docker's "Embedded DNS" server works. VMs can still
  connect to other containers on the same bridge using IP addresses.
