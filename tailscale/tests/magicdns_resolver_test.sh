#!/usr/bin/env bash
# shellcheck shell=bash
set -Eeuo pipefail

# Production breaks caught: tailscaled reuses HA DNS and loops through Quad100,
# ingress re-forwards egress escape-hatch names, dnsmasq is used before it has
# bound, or accept_dns=false forwards ordinary DNS instead of tailnet-only DNS.

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
resolver_script="${repo_root}/tailscale/files/magicdns-resolver.sh"
tmpdir=$(mktemp -d)
trap 'rm -rf "${tmpdir}"' EXIT
mkdir -p "${tmpdir}/bin" "${tmpdir}/runtime"

make_fake() { printf '%s\n' '#!/usr/bin/env bash' 'set -Eeuo pipefail' "$2" > "${tmpdir}/bin/$1"; chmod +x "${tmpdir}/bin/$1"; }
# shellcheck disable=SC2016 # The generated fake expands variables at runtime.
make_fake dig '[[ "$1:$2" == "dns.local.hass.io:A" ]] && echo 172.30.32.3'
make_fake tailscale '
case "$*" in
  *"ip -4") echo 100.111.112.113 ;;
  *"ip -6") echo fd7a:115c:a1e0::1234 ;;
  *"status --json"*) echo "{\"MagicDNSSuffix\":\"example.ts.net\"}" ;;
esac
'
# shellcheck disable=SC2016 # The generated fake expands variables at runtime.
make_fake dnsmasq '
printf "%s\\n" "$*" >> "${FAKE_DNSMASQ_LOG}"
[[ "${FAKE_DNSMASQ_EXIT:-false}" == true ]] && exit 42
sleep 30
'
# shellcheck disable=SC2016 # The generated fake expands variables at runtime.
make_fake ss '
[[ "${FAKE_DNSMASQ_BOUND:-true}" == true ]] || exit 0
case "$*" in
  *" -u "*) printf "%s\\n" "udp UNCONN 0 0 127.100.100.100:53" "udp UNCONN 0 0 100.111.112.113:53" "udp UNCONN 0 0 fd7a:115c:a1e0::1234:53" ;;
  *" -t "*) printf "%s\\n" "tcp LISTEN 0 32 127.100.100.100:53" "tcp LISTEN 0 32 100.111.112.113:53" "tcp LISTEN 0 32 fd7a:115c:a1e0::1234:53" ;;
esac
'
# shellcheck disable=SC2016 # The generated fake expands variables at runtime.
make_fake magicdns-bridge '
printf "%s\\n" "$*" >> "${FAKE_BRIDGE_LOG}"
[[ "$1" == cleanup && "${FAKE_BRIDGE_CLEANUP_FAIL:-false}" == true ]] && exit 51
exit 0
'

run_resolver() {
  PATH="${tmpdir}/bin:${PATH}" FAKE_DNSMASQ_LOG="${tmpdir}/dnsmasq.log" FAKE_BRIDGE_LOG="${tmpdir}/bridge.log" MAGICDNS_RUNTIME_DIR="${tmpdir}/runtime" MAGICDNS_BRIDGE="magicdns-bridge" ACCEPT_DNS="$1" bash "${resolver_script}" "$2"
}

wait_for_log() {
  for _ in 1 2 3 4 5; do
    [[ -s "${tmpdir}/dnsmasq.log" ]] && return 0
    sleep 0.1
  done
  return 1
}

run_resolver true prepare-egress
wait_for_log
grep -Fx 'nameserver 127.100.100.100' "${tmpdir}/runtime/tailscaled-resolv.conf"
grep -F -- '--listen-address=127.100.100.100' "${tmpdir}/dnsmasq.log"
for domain in controlplane.tailscale.com log.tailscale.com acme-v02.api.letsencrypt.org; do
  grep -F -- "--server=/${domain}/172.30.32.3" "${tmpdir}/dnsmasq.log"
done
run_resolver true start-ingress
grep -F -- '--listen-address=100.111.112.113' "${tmpdir}/dnsmasq.log"
grep -F -- '--listen-address=fd7a:115c:a1e0::1234' "${tmpdir}/dnsmasq.log"
for domain in controlplane.tailscale.com log.tailscale.com acme-v02.api.letsencrypt.org; do
  grep -F -- "--server=/${domain}/" "${tmpdir}/dnsmasq.log"
done
grep -Fx setup "${tmpdir}/bridge.log"
run_resolver true cleanup
grep -Fx cleanup "${tmpdir}/bridge.log"

: > "${tmpdir}/dnsmasq.log"
run_resolver false prepare-egress
[[ ! -s "${tmpdir}/dnsmasq.log" ]] || { echo 'FAIL: disabled DNS acceptance started egress proxy' >&2; exit 1; }
run_resolver false start-ingress
grep -F -- '--address=/#/' "${tmpdir}/dnsmasq.log"
grep -F -- '--server=/example.ts.net/100.100.100.100' "${tmpdir}/dnsmasq.log"
run_resolver false cleanup

# Production break caught: failed forwarding cleanup is ignored, so teardown
# removes temporary protection after stopping the resolver and exposes stale DNAT.
run_resolver true prepare-egress
if PATH="${tmpdir}/bin:${PATH}" FAKE_DNSMASQ_LOG="${tmpdir}/dnsmasq.log" FAKE_BRIDGE_LOG="${tmpdir}/bridge-failure.log" FAKE_BRIDGE_CLEANUP_FAIL=true MAGICDNS_RUNTIME_DIR="${tmpdir}/runtime" MAGICDNS_BRIDGE="magicdns-bridge" ACCEPT_DNS=true bash "${resolver_script}" cleanup; then
  echo 'FAIL: resolver cleanup ignored forwarding cleanup failure' >&2
  exit 1
fi
grep -Fx setup-drop "${tmpdir}/bridge-failure.log"
grep -Fx cleanup "${tmpdir}/bridge-failure.log"
if grep -Fxq remove-drop "${tmpdir}/bridge-failure.log"; then
  echo 'FAIL: resolver removed temporary protection after forwarding cleanup failure' >&2
  exit 1
fi
[[ ! -e "${tmpdir}/runtime/magicdns-egress.pid" ]] || { echo 'FAIL: egress resolver survived fail-safe teardown' >&2; exit 1; }

# Production break caught: an immediately exiting dnsmasq is treated as ready
# and leaves an egress resolver file/PID for tailscaled to consume.
rm -f "${tmpdir}/runtime/magicdns-egress.pid" "${tmpdir}/runtime/tailscaled-resolv.conf"
if PATH="${tmpdir}/bin:${PATH}" FAKE_DNSMASQ_LOG="${tmpdir}/dnsmasq.log" FAKE_BRIDGE_LOG="${tmpdir}/bridge.log" FAKE_DNSMASQ_EXIT=true MAGICDNS_RUNTIME_DIR="${tmpdir}/runtime" MAGICDNS_BRIDGE="magicdns-bridge" ACCEPT_DNS=true bash "${resolver_script}" prepare-egress; then
  echo 'FAIL: immediate dnsmasq exit was treated as ready' >&2
  exit 1
fi
[[ ! -e "${tmpdir}/runtime/magicdns-egress.pid" ]] || { echo 'FAIL: failed egress PID remains' >&2; exit 1; }
[[ ! -e "${tmpdir}/runtime/tailscaled-resolv.conf" ]] || { echo 'FAIL: failed egress resolv.conf remains' >&2; exit 1; }

# Production break caught: a live dnsmasq that has not bound either DNS socket
# is accepted as ready and causes tailscaled/forwarding to use a dead resolver.
rm -f "${tmpdir}/runtime/magicdns-egress.pid" "${tmpdir}/runtime/tailscaled-resolv.conf"
if PATH="${tmpdir}/bin:${PATH}" FAKE_DNSMASQ_LOG="${tmpdir}/dnsmasq.log" FAKE_BRIDGE_LOG="${tmpdir}/bridge.log" FAKE_DNSMASQ_BOUND=false MAGICDNS_RUNTIME_DIR="${tmpdir}/runtime" MAGICDNS_BRIDGE="magicdns-bridge" ACCEPT_DNS=true bash "${resolver_script}" prepare-egress; then
  echo 'FAIL: alive-but-unbound dnsmasq was treated as ready' >&2
  exit 1
fi
[[ ! -e "${tmpdir}/runtime/magicdns-egress.pid" ]] || { echo 'FAIL: unbound egress PID remains' >&2; exit 1; }
[[ ! -e "${tmpdir}/runtime/tailscaled-resolv.conf" ]] || { echo 'FAIL: unbound egress resolv.conf remains' >&2; exit 1; }

printf '%s\n' 'PASS: resolver separates tailscaled egress from HA MagicDNS ingress'
