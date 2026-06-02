ARG BUILD_ARCH=amd64
ARG BASE_IMAGE_VERSION=20.1.1
ARG BUILD_FROM=ghcr.io/hassio-addons/base/${BUILD_ARCH}:${BASE_IMAGE_VERSION}

FROM ${BUILD_FROM}

ARG BUILD_ARCH
ARG TAILSCALE_VERSION="v1.98.5"

ENV LANG=C.UTF-8

COPY /files/install.sh /
RUN chmod u+x,go= /install.sh && /install.sh "$BUILD_ARCH" "$TAILSCALE_VERSION"

RUN apk add --no-cache iptables ip6tables

COPY run.sh /
RUN chmod a+x /run.sh

CMD ["/run.sh"]
