#!/usr/bin/env bash
# shellcheck shell=bash
set -Eeuo pipefail

# Exercises the real dnsmasq query path used by the resolver. Production break
# caught: a loop-break name reaches Quad100 from ingress, or a tailnet name does
# not reach Quad100; egress loop-break names must resolve through HA DNS.

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
tmpdir=$(mktemp -d)
trap 'rm -rf "${tmpdir}"' EXIT
mkdir -p "${tmpdir}/bin"

make_fake() {
  local name=$1
  shift
  printf '%s\n' '#!/usr/bin/env bash' 'set -Eeuo pipefail' "$@" > "${tmpdir}/bin/${name}"
  chmod +x "${tmpdir}/bin/${name}"
}

# shellcheck disable=SC2016 # The generated fake expands variables in Alpine.
make_fake dig '
case "${1}:${2}" in
  dns.local.hass.io:A) echo 127.0.0.3 ;;
  *) exec /usr/bin/dig "$@" ;;
esac
'
# shellcheck disable=SC2016 # The generated fake expands variables in Alpine.
make_fake tailscale '
case "$*" in
  "ip -4") echo 127.0.0.2 ;;
  "ip -6") exit 0 ;;
  *"status --json"*) echo "{\"MagicDNSSuffix\":\"example.ts.net\"}" ;;
esac
'
make_fake magicdns-bridge 'exit 0'

# shellcheck disable=SC2016 # The container shell expands its own variables.
rtk podman run --rm --cap-add=NET_ADMIN \
  --authfile /private/tmp/tailscale-podman-empty-auth.json \
  -v "${repo_root}:/work:ro" -v "${tmpdir}:/test:rw" \
  docker.io/library/alpine:3.22 sh -ec '
    apk add --no-cache bash bind-tools dnsmasq iproute2 >/dev/null
    ip addr add 100.100.100.100/32 dev lo
    dnsmasq --no-daemon --no-resolv --no-hosts --bind-interfaces --listen-address=127.0.0.3 --port=53 \
      --address=/controlplane.tailscale.com/198.51.100.10 \
      --address=/log.tailscale.com/198.51.100.11 \
      --address=/acme-v02.api.letsencrypt.org/198.51.100.12 >/test/ha.log 2>&1 &
    ha_pid=$!
    dnsmasq --no-daemon --no-resolv --no-hosts --bind-interfaces --listen-address=100.100.100.100 --port=53 \
      --log-queries --log-facility=/test/quad.log \
      --address=/device.example.ts.net/100.64.0.9 >/test/quad.stderr 2>&1 &
    quad_pid=$!
    trap "kill $ha_pid $quad_pid 2>/dev/null || true" EXIT
    sleep 1
    PATH=/test/bin:$PATH MAGICDNS_RUNTIME_DIR=/test/runtime MAGICDNS_BRIDGE=magicdns-bridge ACCEPT_DNS=true bash /work/tailscale/files/magicdns-resolver.sh prepare-egress
    PATH=/test/bin:$PATH MAGICDNS_RUNTIME_DIR=/test/runtime MAGICDNS_BRIDGE=magicdns-bridge ACCEPT_DNS=true bash /work/tailscale/files/magicdns-resolver.sh start-ingress
    for domain in controlplane.tailscale.com log.tailscale.com acme-v02.api.letsencrypt.org; do
      /usr/bin/dig @127.100.100.100 "$domain" A +short | grep -Eq "^198\.51\.100\."
      /usr/bin/dig @127.0.0.2 "$domain" A +short > "/test/${domain}.ingress"
      ! grep -Fq "$domain" /test/quad.log
    done
    /usr/bin/dig @127.0.0.2 device.example.ts.net A +short | grep -Fx 100.64.0.9
    grep -Fq device.example.ts.net /test/quad.log
    PATH=/test/bin:$PATH MAGICDNS_RUNTIME_DIR=/test/runtime MAGICDNS_BRIDGE=magicdns-bridge ACCEPT_DNS=true bash /work/tailscale/files/magicdns-resolver.sh cleanup
  '

printf '%s\n' 'PASS: real dnsmasq queries keep loop-break names off Quad100 and send tailnet names to it'
