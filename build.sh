#!/usr/bin/env bash
set -e

docker build --tag dsm .
docker images dsm:latest --format "{{.Repository}}:{{.Tag}} -> {{.Size}}"
docker run --rm -it --name dsm --device="/dev/kvm" --cap-add NET_ADMIN -p 80:5000 -p 443:5001 -p 5000:5000 -p 5001:5001 docker.io/library/dsm
