# syntax=docker/dockerfile:1

FROM scratch

COPY --from=qemux/qemu:7.50 / /

ARG VERSION_ARG="0.0"

ARG DEBCONF_NOWARNINGS="yes"
ARG DEBIAN_FRONTEND="noninteractive"
ARG DEBCONF_NONINTERACTIVE_SEEN="true"

RUN <<EOF
  set -eu

  apt-get update
  apt-get --no-install-recommends -y install fakeroot
  apt-get clean

  # Set version file
  echo "$VERSION_ARG" > /etc/version

  rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
EOF

COPY --chmod=755 ./src /run/
COPY --chmod=755 ./web /var/www/
COPY --chmod=744 ./web/conf/nginx.conf /etc/nginx/default.conf
COPY --chmod=755 --from=qemux/qemu-host:2.06 /qemu-host.bin /run/host.bin

VOLUME /storage
EXPOSE 445 5000

ENV RAM_SIZE="2G"
ENV CPU_CORES="2"
ENV DISK_SIZE="256G"

HEALTHCHECK --interval=60s --start-period=45s --retries=2 CMD ["/run/check.sh"]

ENTRYPOINT ["/usr/bin/tini", "-s", "/run/entry.sh"]
