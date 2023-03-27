FROM golang:1.16 AS builder

COPY vdsm-serial/ /src/vdsm-serial/
WORKDIR /src/vdsm-serial
RUN go get -d -v golang.org/x/net/html  
RUN CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -o /src/vdsm-serial/main .

FROM debian:bullseye-20230109-slim

RUN apt-get update && apt-get -y upgrade && \
    apt-get --no-install-recommends -y install \
        iproute2 \
        jq \
        netcat \
        xz-utils \
        unzip \
        wget \
        python3 \
        linux-image-generic \
        libguestfs-tools \
        ca-certificates \
        qemu-system-x86 \
        udhcpd \
    && apt-get clean

COPY generate-dhcpd-conf /run/
COPY qemu-ifdown /run/
COPY qemu-ifup /run/
COPY run.sh /run/
COPY server.sh /run/
COPY --from=builder /src/vdsm-serial/main /run/serial.bin

RUN ["chmod", "+x", "/run/generate-dhcpd-conf"]
RUN ["chmod", "+x", "/run/qemu-ifdown"]
RUN ["chmod", "+x", "/run/qemu-ifup"]
RUN ["chmod", "+x", "/run/run.sh"]
RUN ["chmod", "+x", "/run/server.sh"]
RUN ["chmod", "+x", "/run/serial.bin"]

COPY extractor/lib* /run
#COPY extractor/libcurl.so.4 /usr/lib/x86_64-linux-gnu

COPY extractor/scemd /run/syno_extract_system_patch
RUN ["chmod", "+x", "/run/syno_extract_system_patch"]

COPY disks/template.img.xz /data/

VOLUME /images

EXPOSE 5000
EXPOSE 5001

ENTRYPOINT ["/run/run.sh"]

# Mostly users will probably want to configure memory usage.
CMD ["-m", "512M"]

