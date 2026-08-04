ARG BUILD_ARCH=amd64
ARG BASE_IMAGE_VERSION=21.0.1
ARG BUILD_FROM=ghcr.io/hassio-addons/base/${BUILD_ARCH}:${BASE_IMAGE_VERSION}

FROM ${BUILD_FROM}

ARG BUILD_ARCH
ARG TAILSCALE_VERSION="v1.102.1"

ENV LANG=C.UTF-8

COPY /files/install.sh /
RUN chmod u+x,go= /install.sh && /install.sh "$BUILD_ARCH" "$TAILSCALE_VERSION"

RUN apk add --no-cache iptables ip6tables dnsmasq bind-tools util-linux

COPY run.sh /
COPY files/magicdns-bridge.sh /magicdns-bridge.sh
COPY files/magicdns-resolver.sh /magicdns-resolver.sh
RUN chmod a+x /run.sh /magicdns-bridge.sh /magicdns-resolver.sh

CMD ["/run.sh"]
