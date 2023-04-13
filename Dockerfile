FROM golang:1.20 AS builder

COPY serial/ /src/serial/
WORKDIR /src/serial

RUN go get -d -v golang.org/x/net/html
RUN go get -d -v github.com/gorilla/mux
RUN CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -o /src/serial/main .

FROM debian:bookworm-20230320-slim

RUN apt-get update && apt-get -y upgrade && \
    apt-get --no-install-recommends -y install \
	curl \
	cpio \
	wget \
	unzip \
	procps \
	dnsmasq \
	iptables \
	iproute2 \
	xz-utils \
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
RUN ["chmod", "+x", "/run/server.sh"]
RUN ["chmod", "+x", "/run/install.sh"]
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

ENV URL ""
ENV CPU_CORES 1
ENV DISK_SIZE 16G
ENV RAM_SIZE 512M

ENTRYPOINT ["/run/run.sh"]
