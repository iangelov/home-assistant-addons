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
  dns.local.hass.io:A) [[ "${FAKE_CHANGED_ADDRESS:-false}" == true ]] && echo 172.30.33.3 || echo 172.30.32.3 ;;
  dns.local.hass.io:AAAA) [[ "${FAKE_CHANGED_ADDRESS:-false}" == true ]] && echo fd00::33 || echo fd00::3 ;;
  supervisor.local.hass.io:A) [[ "${FAKE_CHANGED_ADDRESS:-false}" == true ]] && echo 172.30.33.2 || echo 172.30.32.2 ;;
  supervisor.local.hass.io:AAAA) [[ "${FAKE_CHANGED_ADDRESS:-false}" == true ]] && echo fd00::32 || echo fd00::2 ;;
esac
'
# shellcheck disable=SC2016 # The generated fake expands variables at runtime.
make_fake tailscale '
case "$*" in
  *" ip -4") [[ "${FAKE_CHANGED_ADDRESS:-false}" == true ]] && echo 100.111.112.114 || echo 100.111.112.113 ;;
  *" ip -6") [[ "${FAKE_CHANGED_ADDRESS:-false}" == true ]] && echo fd7a:115c:a1e0::1235 || echo fd7a:115c:a1e0::1234 ;;
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
  *" -I "*)
    insert=${args/ -I / -A }
    { printf "%s\\n" "$insert"; cat "$state"; } > "${state}.next"
    mv "${state}.next" "$state"
    ;;
  *" -D "*)
    [[ "${FAKE_FAIL_DELETE:-false}" == true ]] && exit 45
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

# Production break caught: Quad100 is reachable during daemon startup or
# teardown instead of being held by exact temporary DROP DNAT rules.
run_bridge setup-drop
assert_rule_count 8 "${tmpdir}/state/iptables"
assert_rule_count 8 "${tmpdir}/state/ip6tables"
assert_contains '-s 172.30.32.3 -d 100.100.100.100 -i hassio -p udp --dport 53 -j DNAT --to-destination 127.0.0.1:0' "${tmpdir}/state/iptables"
# Production break caught: temporary protection appended after an existing
# forwarding rule cannot prevent Quad100 traffic from reaching a stopped DNS.
first_ipv4_rule=$(head -n 1 "${tmpdir}/state/iptables")
[[ "${first_ipv4_rule}" == *'--to-destination 127.0.0.1:0'* ]] || {
  echo 'FAIL: temporary IPv4 deny rule does not take precedence' >&2
  exit 1
}
run_bridge setup
assert_rule_count 4 "${tmpdir}/state/iptables"
assert_rule_count 4 "${tmpdir}/state/ip6tables"

# Production break caught: cleanup discovers changed addresses and leaves the
# exact forwarding rules installed by the prior process behind.
FAKE_CHANGED_ADDRESS=true run_bridge cleanup
[[ ! -s "${tmpdir}/state/iptables" ]] || { echo 'FAIL: cached IPv4 rules remain after address change' >&2; exit 1; }
[[ ! -s "${tmpdir}/state/ip6tables" ]] || { echo 'FAIL: cached IPv6 rules remain after address change' >&2; exit 1; }

run_bridge setup

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

# Production break caught: a forwarding deletion failure must leave the
# precedence deny rule installed, rather than exposing stale forwarding.
run_bridge setup
run_bridge setup-drop
if PATH="${tmpdir}/bin:${PATH}" FAKE_NAT_STATE="${tmpdir}/state" FAKE_FAIL_DELETE=true MAGICDNS_RUNTIME_DIR="${tmpdir}/runtime" TAILSCALE_SOCKET="${tmpdir}/tailscaled.sock" bash "${bridge_script}" cleanup; then
  echo 'FAIL: cleanup unexpectedly succeeded when forwarding deletion failed' >&2
  exit 1
fi
first_ipv4_rule=$(head -n 1 "${tmpdir}/state/iptables")
[[ "${first_ipv4_rule}" == *'--to-destination 127.0.0.1:0'* ]] || {
  echo 'FAIL: cleanup removed protection after forwarding deletion failed' >&2
  exit 1
}

printf '%s\n' 'PASS: MagicDNS bridge dynamically forwards both DNS transports and cleans up safely'
