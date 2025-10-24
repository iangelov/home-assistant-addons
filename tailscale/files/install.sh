#!/usr/bin/env bash
set -Eeum -o pipefail

echo "ARGS: $*"

BUILD_ARCH="$1"
TAILSCALE_VERSION="${2#v}"

case "$BUILD_ARCH" in
  "armhf" | "armv7")
    TAILSCALE_ARCH="arm"
    ;;
  "aarch64")
    TAILSCALE_ARCH="arm64"
    ;;
  "amd64")
    TAILSCALE_ARCH="amd64"
    ;;
  "i386")
    TAILSCALE_ARCH="386"
    ;;
esac

echo "Downloading Tailscale ${TAILSCALE_VERSION} for ${BUILD_ARCH}..."

curl -Ss "https://pkgs.tailscale.com/stable/tailscale_${TAILSCALE_VERSION}_${TAILSCALE_ARCH}.tgz" -o - | tar zxf -
mv "tailscale_${TAILSCALE_VERSION}_${TAILSCALE_ARCH}/tailscale"* /bin/
rm -rf "tailscale_${TAILSCALE_VERSION}_${TAILSCALE_ARCH}"
