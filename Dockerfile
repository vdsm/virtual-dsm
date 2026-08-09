# syntax=docker/dockerfile:1

FROM qemux/qemu-host:2.06 AS host
FROM scratch

COPY --from=qemux/qemu:7.45 / /

ARG TARGETARCH

ARG VERSION_ARG="0.0"
ARG VERSION_CSTRUCT="4.7"

ARG DEBCONF_NOWARNINGS="yes"
ARG DEBIAN_FRONTEND="noninteractive"
ARG DEBCONF_NONINTERACTIVE_SEEN="true"

RUN <<EOF
  set -eu

  apt-get update
  apt-get --no-install-recommends -y install \
    fakeroot \
    python3-msgpack \
    python3-pysodium

  apt-get clean

  # Install Python dependencies
  pip3 install --no-cache-dir --break-system-packages --root-user-action=ignore "dissect.cstruct==$VERSION_CSTRUCT"

  # Set version file
  echo "$VERSION_ARG" > /etc/version

  rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
EOF

COPY --chmod=755 ./src /run/
COPY --chmod=755 ./web /var/www/
COPY --chmod=755 --from=host /qemu-host.bin /run/host.bin
COPY --chmod=744 ./web/conf/nginx.conf /etc/nginx/default.conf
ADD --chmod=775 https://raw.githubusercontent.com/sud0woodo/patology/refs/heads/main/patology.py /run/extract.py

VOLUME /storage
EXPOSE 445 5000

ENV RAM_SIZE="2G"
ENV CPU_CORES="2"
ENV DISK_SIZE="256G"

HEALTHCHECK --interval=60s --start-period=45s --retries=2 CMD ["/run/check.sh"]

ENTRYPOINT ["/usr/bin/tini", "-s", "/run/entry.sh"]
