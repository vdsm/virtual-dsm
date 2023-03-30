FROM golang:1.16 AS builder

COPY serial/ /src/serial/
WORKDIR /src/serial
RUN go get -d -v golang.org/x/net/html  
RUN CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -o /src/serial/main .

FROM debian:bookworm-20230320-slim

RUN apt-get update && apt-get -y upgrade && \
    apt-get --no-install-recommends -y install \
	iproute2 \
	jq \
	wget \
	unzip \
	parted \
	procps \
	python3 \
	xz-utils \
	ca-certificates \
	netcat-openbsd \
	qemu-system-x86 \
	udhcpd \
    && apt-get clean

COPY generate-dhcpd-conf /run/
COPY qemu-ifdown /run/
COPY qemu-ifup /run/
COPY run.sh /run/
COPY serial.sh /run/
COPY server.sh /run/
COPY install.sh /run/
COPY --from=builder /src/serial/main /run/serial.bin

RUN ["chmod", "+x", "/run/generate-dhcpd-conf"]
RUN ["chmod", "+x", "/run/qemu-ifdown"]
RUN ["chmod", "+x", "/run/qemu-ifup"]
RUN ["chmod", "+x", "/run/run.sh"]
RUN ["chmod", "+x", "/run/serial.sh"]
RUN ["chmod", "+x", "/run/server.sh"]
RUN ["chmod", "+x", "/run/install.sh"]

COPY extractor/lib* /run/extract/
COPY extractor/scemd /run/extract/syno_extract_system_patch
 
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

ENV URL https://global.synologydownload.com/download/DSM/beta/7.2/64216/DSM_VirtualDSM_64216.pat
#ENV URL https://global.synologydownload.com/download/DSM/release/7.0.1/42218/DSM_VirtualDSM_42218.pat
#ENV URL https://global.synologydownload.com/download/DSM/release/7.1.1/42962-1/DSM_VirtualDSM_42962.pat

ENTRYPOINT ["/run/run.sh"]

