FROM qemux/qemu-host AS host
FROM debian:bookworm-slim

ARG DEBCONF_NOWARNINGS="yes"
ARG DEBIAN_FRONTEND noninteractive

RUN apt-get update && apt-get -y upgrade && \
        apt-get --no-install-recommends -y install \
        curl \
        cpio \
        wget \
        fdisk \
        unzip \
        procps \
        xz-utils \
        iptables \
        iproute2 \
        dnsmasq \
        net-tools \
        btrfs-progs \
        ca-certificates \
        isc-dhcp-client \
        netcat-openbsd \
        qemu-system-x86 \
    && apt-get clean

COPY run/*.sh /run/
COPY agent/*.sh /agent/

COPY --from=host /qemu-host.bin /run/host.bin

RUN ["chmod", "+x", "/run/run.sh"]
RUN ["chmod", "+x", "/run/check.sh"]
RUN ["chmod", "+x", "/run/server.sh"]
RUN ["chmod", "+x", "/run/host.bin"]

VOLUME /storage

EXPOSE 22
EXPOSE 80
EXPOSE 139 
EXPOSE 443 
EXPOSE 445
EXPOSE 5000

ENV CPU_CORES "1"
ENV DISK_SIZE "16G"
ENV RAM_SIZE "512M"

ARG DATE_ARG=""
ARG BUILD_ARG=0
ARG VERSION_ARG="0.0"
ENV VERSION=$VERSION_ARG

LABEL org.opencontainers.image.created=${DATE_ARG}
LABEL org.opencontainers.image.revision=${BUILD_ARG}
LABEL org.opencontainers.image.version=${VERSION_ARG}
LABEL org.opencontainers.image.source=https://github.com/kroese/virtual-dsm/
LABEL org.opencontainers.image.url=https://hub.docker.com/r/kroese/virtual-dsm/

HEALTHCHECK --interval=30s --retries=1 CMD /run/check.sh

ENTRYPOINT ["/run/run.sh"]
