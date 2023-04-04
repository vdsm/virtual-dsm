FROM golang:1.20 AS builder

COPY serial/ /src/serial/
WORKDIR /src/serial
RUN go get -d -v golang.org/x/net/html  
RUN CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -o /src/serial/main .

FROM debian:bookworm-20230320-slim

RUN apt-get update && apt-get -y upgrade && \
    apt-get --no-install-recommends -y install \
	jq \
	curl \
	cpio \
	wget \
	unzip \
	procps \
	ethtool \
	dnsmasq \
	iptables \
	iproute2 \
	xz-utils \
	qemu-utils \
	btrfs-progs \
	bridge-utils \
	netcat-openbsd \
	ca-certificates \
	qemu-system-x86 \
    && apt-get clean

COPY run.sh /run/
COPY disk.sh /run/
COPY power.sh /run/
COPY serial.sh /run/
COPY server.sh /run/
COPY install.sh /run/
COPY network.sh /run/
COPY agent/agent.sh /agent/
COPY agent/service.sh /agent/

COPY --from=builder /src/serial/main /run/serial.bin

RUN ["chmod", "+x", "/run/run.sh"]
RUN ["chmod", "+x", "/run/disk.sh"]
RUN ["chmod", "+x", "/run/power.sh"]
RUN ["chmod", "+x", "/run/serial.sh"]
RUN ["chmod", "+x", "/run/server.sh"]
RUN ["chmod", "+x", "/run/install.sh"]
RUN ["chmod", "+x", "/run/network.sh"]
RUN ["chmod", "+x", "/run/serial.bin"]

COPY disks/template.img.xz /data/

VOLUME /storage

EXPOSE 22
EXPOSE 80
EXPOSE 139 
EXPOSE 443 
EXPOSE 445
EXPOSE 5000
EXPOSE 5001

ENV RAM_SIZE 512M
ENV DISK_SIZE 16G
ENV CPU_CORES 1

#ENV URL https://global.synologydownload.com/download/DSM/beta/7.2/64216/DSM_VirtualDSM_64216.pat
#ENV URL https://global.synologydownload.com/download/DSM/release/7.0.1/42218/DSM_VirtualDSM_42218.pat
ENV URL https://global.synologydownload.com/download/DSM/release/7.1.1/42962-1/DSM_VirtualDSM_42962.pat

ENTRYPOINT ["/run/run.sh"]
