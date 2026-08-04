#!/usr/bin/env bash
# shellcheck shell=bash
set -Eeuo pipefail

# Production breaks caught: static HA/Tailscale addresses, UDP-only forwarding,
# duplicate restart rules, broad cleanup, and setup failures leaving NAT state.

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
bridge_script="${repo_root}/tailscale/files/magicdns-bridge.sh"
tmpdir=$(mktemp -d)
trap 'rm -rf "${tmpdir}"' EXIT
mkdir -p "${tmpdir}/bin" "${tmpdir}/state"

make_fake() {
  local name=$1
  shift
  printf '%s\n' '#!/usr/bin/env bash' 'set -Eeuo pipefail' "$@" > "${tmpdir}/bin/${name}"
  chmod +x "${tmpdir}/bin/${name}"
}

# shellcheck disable=SC2016 # The generated fake expands variables at runtime.
make_fake dig '
case "$1:$2" in
  dns.local.hass.io:A) echo 172.30.32.3 ;;
  dns.local.hass.io:AAAA) echo fd00::3 ;;
  supervisor.local.hass.io:A) echo 172.30.32.2 ;;
  supervisor.local.hass.io:AAAA) echo fd00::2 ;;
esac
'
make_fake tailscale '
case "$*" in
  *" ip -4") echo 100.111.112.113 ;;
  *" ip -6") echo fd7a:115c:a1e0::1234 ;;
  *" status --json"*) echo "{\"MagicDNSSuffix\":\"example.ts.net\"}" ;;
esac
'
# shellcheck disable=SC2016 # The generated fake expands variables at runtime.
make_fake iptables '
state="${FAKE_NAT_STATE}/$(basename "$0")"
mkdir -p "${FAKE_NAT_STATE}"
touch "$state"
args="$*"
case " $args " in
  *" -C "*) check=${args/ -C / -A }; grep -Fqx -- "$check" "$state" ;;
  *" -A "*)
    if [[ "${FAKE_FAIL_ADD_AT:-0}" != 0 ]]; then
      count=$(grep -c -- " -A " "$state" || true)
      [[ "$count" -ge "$FAKE_FAIL_ADD_AT" ]] && exit 44
    fi
    printf "%s\\n" "$args" >> "$state"
    ;;
  *" -D "*)
    delete=${args/ -D / -A }
    grep -Fvx -- "$delete" "$state" > "${state}.next" || true
    mv "${state}.next" "$state"
    ;;
esac
'
cp "${tmpdir}/bin/iptables" "${tmpdir}/bin/ip6tables"

run_bridge() {
  PATH="${tmpdir}/bin:${PATH}" \
    FAKE_NAT_STATE="${tmpdir}/state" \
    MAGICDNS_RUNTIME_DIR="${tmpdir}/runtime" \
    TAILSCALE_SOCKET="${tmpdir}/tailscaled.sock" \
    bash "${bridge_script}" "$@"
}

assert_contains() {
  local expected=$1 file=$2
  if ! grep -Fq -- "$expected" "$file"; then
    printf 'FAIL: expected %s in %s\n' "$expected" "$file" >&2
    return 1
  fi
}

assert_rule_count() {
  local expected=$1 file=$2
  local actual
  actual=$(grep -c -- ' -A PREROUTING -s ' "$file" || true)
  [[ "$actual" == "$expected" ]] || {
    printf 'FAIL: expected %s forwarding rules, got %s\n' "$expected" "$actual" >&2
    return 1
  }
}

if ! run_bridge setup; then
  printf '%s\n' 'FAIL: setup should install the bridge rules' >&2
  exit 1
fi
assert_rule_count 4 "${tmpdir}/state/iptables"
assert_rule_count 4 "${tmpdir}/state/ip6tables"
assert_contains '-s 172.30.32.3 -d 100.100.100.100 -i hassio -p udp --dport 53 -j DNAT --to-destination 100.111.112.113:53' "${tmpdir}/state/iptables"
assert_contains '-s 172.30.32.2 -d 100.100.100.100 -i hassio -p tcp --dport 53 -j DNAT --to-destination 100.111.112.113:53' "${tmpdir}/state/iptables"
assert_contains '-s fd00::3 -d fd7a:115c:a1e0::53 -i hassio -p udp --dport 53 -j DNAT --to-destination [fd7a:115c:a1e0::1234]:53' "${tmpdir}/state/ip6tables"

run_bridge setup
assert_rule_count 4 "${tmpdir}/state/iptables"
assert_rule_count 4 "${tmpdir}/state/ip6tables"

printf '%s\n' 'UNRELATED -t nat -A PREROUTING -d 192.0.2.9 -j DNAT --to-destination 192.0.2.10' >> "${tmpdir}/state/iptables"
run_bridge cleanup
grep -Fx 'UNRELATED -t nat -A PREROUTING -d 192.0.2.9 -j DNAT --to-destination 192.0.2.10' "${tmpdir}/state/iptables"
[[ ! -s "${tmpdir}/state/ip6tables" ]] || { echo 'FAIL: matching IPv6 rules remain after cleanup' >&2; exit 1; }

printf '%s\n' 'UNRELATED -t nat -A PREROUTING -d 192.0.2.9 -j DNAT --to-destination 192.0.2.10' > "${tmpdir}/state/iptables"
if PATH="${tmpdir}/bin:${PATH}" FAKE_NAT_STATE="${tmpdir}/state" FAKE_FAIL_ADD_AT=2 MAGICDNS_RUNTIME_DIR="${tmpdir}/runtime" TAILSCALE_SOCKET="${tmpdir}/tailscaled.sock" bash "${bridge_script}" setup; then
  echo 'FAIL: setup unexpectedly succeeded after injected firewall failure' >&2
  exit 1
fi
grep -Fx 'UNRELATED -t nat -A PREROUTING -d 192.0.2.9 -j DNAT --to-destination 192.0.2.10' "${tmpdir}/state/iptables"
assert_rule_count 0 "${tmpdir}/state/iptables"

printf '%s\n' 'PASS: MagicDNS bridge dynamically forwards both DNS transports and cleans up safely'
