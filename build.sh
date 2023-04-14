#!/usr/bin/env bash
set -e

docker build --tag dsm .
docker images dsm:latest --format "{{.Repository}}:{{.Tag}} -> {{.Size}}"
docker run --rm -it --name dsm -p 5000:5000  --device=/dev/kvm --cap-add NET_ADMIN --stop-timeout 60 docker.io/library/dsm
