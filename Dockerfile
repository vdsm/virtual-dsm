FROM debian:bullseye-20230109-slim

RUN apt-get update && apt-get -y upgrade && \
    apt-get --no-install-recommends -y install \
        iproute2 \
        jq \
        python3 \
        qemu-system-x86 \
        udhcpd \
    && apt-get clean

COPY generate-dhcpd-conf /run/
COPY qemu-ifdown /run/
COPY qemu-ifup /run/
COPY run.sh /run/

RUN ["chmod", "+x", "/run/generate-dhcpd-conf"]
RUN ["chmod", "+x", "/run/qemu-ifdown"]
RUN ["chmod", "+x", "/run/qemu-ifup"]
RUN ["chmod", "+x", "/run/run.sh"]

VOLUME /image

EXPOSE 5000
EXPOSE 5001

ENTRYPOINT ["/run/run.sh"]

# Mostly users will probably want to configure memory usage.
CMD ["-m", "512M"]
