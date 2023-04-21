FROM golang:1.20 AS builder

COPY serial/ /src/serial/
WORKDIR /src/serial

RUN go get -d -v golang.org/x/net/html
RUN go get -d -v github.com/gorilla/mux
RUN CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -o /src/serial/main .

FROM debian:bookworm-20230411-slim

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
	bridge-utils \
	ca-certificates \
	isc-dhcp-client \
	netcat-openbsd \
	qemu-system-x86 \
    && apt-get clean

COPY run/*.sh /run/
COPY agent/*.sh /agent/

COPY --from=builder /src/serial/main /run/serial.bin

RUN ["chmod", "+x", "/run/run.sh"]
RUN ["chmod", "+x", "/run/server.sh"]
RUN ["chmod", "+x", "/run/serial.bin"]

VOLUME /storage

EXPOSE 22
EXPOSE 80
EXPOSE 139 
EXPOSE 443 
EXPOSE 445
EXPOSE 5000
EXPOSE 5001

ENV URL ""
ENV ALLOCATE "Y"
ENV CPU_CORES "1"
ENV DISK_SIZE "16G"
ENV RAM_SIZE "512M"
ENV HOST_SERIAL ""
ENV GUEST_SERIAL ""

ARG DATE_ARG=""
ARG BUILD_ARG=0
ARG VERSION_ARG="0.0"
ENV VERSION=$VERSION_ARG

LABEL org.opencontainers.image.created=${DATE_ARG}
LABEL org.opencontainers.image.revision=${BUILD_ARG}
LABEL org.opencontainers.image.version=${VERSION_ARG}
LABEL org.opencontainers.image.url=https://hub.docker.com/r/kroese/virtual-dsm/
LABEL org.opencontainers.image.source=https://github.com/kroese/virtual-dsm/

HEALTHCHECK --interval=30s --timeout=2s CMD curl -ILfSs http://20.20.20.21:5000/ || exit 1

ENTRYPOINT ["/run/run.sh"]
