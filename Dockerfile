# syntax=docker/dockerfile:1

FROM qemux/qemu-host:2.05 AS builder

#  FROM golang as builder
#  WORKDIR /
#  RUN git clone https://github.com/qemus/qemu-host.git
#  WORKDIR /qemu-host/src
#  RUN go mod download
#  RUN CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -o /qemu-host.bin .

FROM debian:trixie-slim

ARG TARGETPLATFORM
ARG VERSION_ARG="0.0"
ARG DEBCONF_NOWARNINGS="yes"
ARG DEBIAN_FRONTEND="noninteractive"
ARG DEBCONF_NONINTERACTIVE_SEEN="true"

RUN set -eu && \
    apt-get update && \
    apt-get --no-install-recommends -y install \
        jq \
        tini \
        curl \
        wget \
        fdisk \
        unzip \
        nginx \
        procps \
        ethtool \
        python3 \
        python3-pip \
        python3-msgpack \
        python3-pysodium \
        xz-utils \
        iptables \
        iproute2 \
        apt-utils \
        dnsmasq \
        fakeroot \
        net-tools \
        e2fsprogs \
        qemu-utils \
        iputils-ping \
        ca-certificates \
        netcat-openbsd \
        qemu-system-x86 && \
    apt-get clean && \
    pip3 install --no-cache-dir --break-system-packages --root-user-action=ignore dissect.cstruct && \
    mkdir -p /etc/qemu && \
    echo "allow br0" > /etc/qemu/bridge.conf && \
    unlink /etc/nginx/sites-enabled/default && \
    sed -i 's/^worker_processes.*/worker_processes 1;/' /etc/nginx/nginx.conf && \
    echo "$VERSION_ARG" > /run/version && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

COPY --chmod=755 ./src /run/
COPY --chmod=755 ./web /var/www/
COPY --chmod=755 --from=builder /qemu-host.bin /run/host.bin
COPY --chmod=744 ./web/conf/nginx.conf /etc/nginx/default.conf
ADD --chmod=775 https://raw.githubusercontent.com/sud0woodo/patology/refs/heads/main/patology.py /run/extract.py

VOLUME /storage
EXPOSE 22 139 445 5000

ENV RAM_SIZE="2G"
ENV CPU_CORES="2"
ENV DISK_SIZE="16G"

HEALTHCHECK --interval=60s --start-period=45s --retries=2 CMD /run/check.sh

ENTRYPOINT ["/usr/bin/tini", "-s", "/run/entry.sh"]
