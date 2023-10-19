FROM qemux/qemu-host as builder

#  FROM golang as builder
#  WORKDIR /
#  RUN git clone https://github.com/qemu-tools/qemu-host.git
#  WORKDIR /qemu-host/src
#  RUN go mod download
#  RUN CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -o /qemu-host.bin .

FROM debian:trixie-slim

ARG DEBCONF_NOWARNINGS="yes"
ARG DEBIAN_FRONTEND noninteractive

RUN apt-get update && apt-get -y upgrade && \
    apt-get --no-install-recommends -y install \
        tini \    
        curl \
        cpio \
        wget \
        fdisk \
        unzip \
        socat \
        procps \
        xz-utils \
        iptables \
        iproute2 \
        dnsmasq \
        net-tools \
        ca-certificates \
        netcat-openbsd \
        qemu-system-x86 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

COPY run/*.sh /run/
COPY agent/*.sh /agent/

COPY --from=builder /qemu-host.bin /run/host.bin

RUN chmod +x /run/*.sh && chmod +x /run/*.bin

VOLUME /storage

EXPOSE 22
EXPOSE 80
EXPOSE 139
EXPOSE 445
EXPOSE 5000

ENV CPU_CORES "1"
ENV DISK_SIZE "16G"
ENV RAM_SIZE "512M"

ARG DATE_ARG=""
ARG BUILD_ARG=0
ARG VERSION_ARG="0.0"
ENV VERSION=$VERSION_ARG

LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.title="Virtual DSM"
LABEL org.opencontainers.image.created=${DATE_ARG}
LABEL org.opencontainers.image.revision=${BUILD_ARG}
LABEL org.opencontainers.image.version=${VERSION_ARG}
LABEL org.opencontainers.image.source="https://github.com/vdsm/virtual-dsm/"
LABEL org.opencontainers.image.url="https://hub.docker.com/r/vdsm/virtual-dsm/"
LABEL org.opencontainers.image.description="Virtual DSM in a docker container"

HEALTHCHECK --interval=60s --retries=2 CMD /run/check.sh

ENTRYPOINT ["/usr/bin/tini", "-s", "/run/run.sh"]
