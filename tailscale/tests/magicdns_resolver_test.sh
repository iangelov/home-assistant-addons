#!/usr/bin/env bash
# shellcheck shell=bash
set -Eeuo pipefail

# Production break caught: tailscaled reuses HA DNS and loops through Quad100,
# or accept_dns=false forwards ordinary DNS instead of tailnet-only DNS.

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
make_fake dnsmasq 'printf "%s\\n" "$*" >> "${FAKE_DNSMASQ_LOG}"; sleep 30'
# shellcheck disable=SC2016 # The generated fake expands variables at runtime.
make_fake magicdns-bridge 'printf "%s\\n" "$*" >> "${FAKE_BRIDGE_LOG}"'

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
grep -F -- '--server=/controlplane.tailscale.com/172.30.32.3' "${tmpdir}/dnsmasq.log"
run_resolver true start-ingress
grep -F -- '--listen-address=100.111.112.113' "${tmpdir}/dnsmasq.log"
grep -F -- '--listen-address=fd7a:115c:a1e0::1234' "${tmpdir}/dnsmasq.log"
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

printf '%s\n' 'PASS: resolver separates tailscaled egress from HA MagicDNS ingress'
