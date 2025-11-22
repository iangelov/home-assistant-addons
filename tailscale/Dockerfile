ARG BUILD_FROM

FROM ${BUILD_FROM}

ARG BUILD_ARCH
ARG TAILSCALE_VERSION

ENV LANG=C.UTF-8

COPY /files/install.sh /
RUN chmod u+x,go= /install.sh && /install.sh "$BUILD_ARCH" "$TAILSCALE_VERSION"

RUN apk add --no-cache iptables ip6tables

COPY run.sh /
RUN chmod a+x /run.sh

CMD ["/run.sh"]
