FROM qemux/qemu-host as builder

#  FROM golang as builder
#  WORKDIR /
#  RUN git clone https://github.com/qemu-tools/qemu-host.git
#  WORKDIR /qemu-host/src
#  RUN go mod download
#  RUN CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -o /qemu-host.bin .

FROM debian:trixie-slim

ARG TARGETPLATFORM
ARG DEBCONF_NOWARNINGS="yes"
ARG DEBIAN_FRONTEND noninteractive

RUN apt-get update && apt-get -y upgrade \
    && if [ "$TARGETPLATFORM" != "linux/amd64" ]; then extra="qemu-user"; fi \
    && apt-get --no-install-recommends -y install \
        jq \
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
        fakeroot \
        net-tools \
        qemu-utils \
        ca-certificates \
        netcat-openbsd \
        qemu-system-x86 \
        "$extra" \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

COPY ./src /run/
COPY --from=builder /qemu-host.bin /run/host.bin
RUN chmod +x /run/*.sh && chmod +x /run/*.bin

VOLUME /storage
EXPOSE 22 80 139 445 5000

ENV RAM_SIZE "1G"
ENV DISK_SIZE "16G"
ENV CPU_CORES "1"

ARG VERSION_ARG="0.0"
RUN echo "$VERSION_ARG" > /run/version

HEALTHCHECK --interval=60s --start-period=45s --retries=2 CMD /run/check.sh

ENTRYPOINT ["/usr/bin/tini", "-s", "/run/entry.sh"]
