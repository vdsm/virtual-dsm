# qemu-docker

[![Build Status](https://travis-ci.org/joshkunz/qemu-docker.svg?branch=master)](https://travis-ci.org/joshkunz/qemu-docker)

This repository contains a Docker container for running x86\_64 virtual
machines using QEMU. It uses high-performance QEMU options
(KVM, and TAP network driver).

Docker Hub: [jkz0/qemu](https://hub.docker.com/r/jkz0/qemu)

## Using the container

Via `docker run`:

```bash
$ docker run --rm -it \
    --device=/dev/kvm:/dev/kvm --device=/dev/net/tun:/dev/net/tun \
    --cap-add NET_ADMIN -v $VM_IMAGE_FILE:/image \
    jkz0/qemu:latest
```

Via `docker-compose.yml`:

```yaml
version: "3"
services:
    vm:
        image: jkz0/qemu:latest
        cap_add:
            - NET_ADMIN
        devices:
            - /dev/net/tun
            - /dev/kvm
        volumes:
            - ${VM_IMAGE:?VM image must be supplied}:/image
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
