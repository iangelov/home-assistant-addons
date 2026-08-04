#!/usr/bin/env bash
# shellcheck shell=bash
set -Eeuo pipefail

# Production break caught: tailscale up --reset omits or reverses --accept-dns,
# leaving DNS behavior dependent on the previous daemon state.

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
run_script="${repo_root}/tailscale/run.sh"
tmpdir=$(mktemp -d)
trap 'rm -rf "${tmpdir}"' EXIT

mkdir -p "${tmpdir}/bin" "${tmpdir}/socket"

make_fake() {
  local name=$1
  shift
  printf '%s\n' '#!/usr/bin/env bash' 'set -Eeuo pipefail' "$@" > "${tmpdir}/bin/${name}"
  chmod +x "${tmpdir}/bin/${name}"
}

# shellcheck disable=SC2016 # The generated fake expands variables at runtime.
make_fake 'bashio::config.true' '
if [[ "${1}" == "accept_dns" && "${FAKE_ACCEPT_DNS}" == true ]]; then exit 0; fi
if [[ "${FAKE_EXISTING_OPTIONS:-false}" == true ]]; then
  case "${1}" in
    advertise_exit_node|advertise_connector|proxy_serve_ha|webclient) exit 0 ;;
  esac
fi
exit 1
'
# shellcheck disable=SC2016 # The generated fake expands variables at runtime.
make_fake 'bashio::config.has_value' '
[[ "${FAKE_EXISTING_OPTIONS:-false}" == true ]] || exit 1
case "${1}" in advertised_routes|tags|hostname|port) exit 0 ;; esac
exit 1
'
# shellcheck disable=SC2016 # The generated fake expands variables at runtime.
make_fake 'bashio::config' '
case "${1}" in
  advertised_routes) echo 192.0.2.0/24 ;;
  tags) echo tag:existing ;;
  hostname) echo existing-host ;;
  port) echo 41642 ;;
esac
'
# shellcheck disable=SC2016 # The generated fake expands variables at runtime.
make_fake tailscaled '
if [[ "${1-}" == "-cleanup" ]]; then exit 0; fi
: > "${TAILSCALE_SOCKET}"
sleep 0.01
'
# shellcheck disable=SC2016 # The generated fake expands variables at runtime.
make_fake tailscale '
printf "%s\\n" "$*" >> "${TAILSCALE_TEST_LOG}"
exit 0
'
# shellcheck disable=SC2016 # The generated fake expands variables at runtime.
make_fake magicdns-resolver '
printf "%s\\n" "$*" >> "${MAGICDNS_TEST_LOG}"
if [[ "$1" == prepare-egress && "${FAKE_PREPARE_FAIL:-false}" == true ]]; then exit 73; fi
'
# shellcheck disable=SC2016 # The generated fake expands variables at runtime.
make_fake unshare '
printf "%s\\n" "$*" >> "${UNSHARE_TEST_LOG}"
[[ "${FAKE_UNSHARE_FAIL:-false}" == true ]] && exit 74
"${@:7}"
'

run_case() {
  local accept_dns=$1
  : > "${tmpdir}/calls-${accept_dns}.log"
  PATH="${tmpdir}/bin:${PATH}" \
    TAILSCALE_SOCKET="${tmpdir}/socket/tailscaled.sock" \
    TAILSCALE_TEST_LOG="${tmpdir}/calls-${accept_dns}.log" \
    MAGICDNS_RESOLVER="${tmpdir}/bin/magicdns-resolver" \
    MAGICDNS_TEST_LOG="${tmpdir}/magicdns-${accept_dns}.log" \
    UNSHARE_TEST_LOG="${tmpdir}/unshare-${accept_dns}.log" \
    FAKE_ACCEPT_DNS="${accept_dns}" \
    timeout 7 bash "${run_script}" >/dev/null 2>&1 || true
  if ! grep -Fx -- "--socket ${tmpdir}/socket/tailscaled.sock up --reset --accept-dns=${accept_dns}" \
    "${tmpdir}/calls-${accept_dns}.log"; then
    printf 'FAIL: expected deterministic --accept-dns=%s tailscale up invocation\n' "${accept_dns}" >&2
    return 1
  fi
  if [[ "${accept_dns}" == true ]]; then
    grep -Fx prepare-egress "${tmpdir}/magicdns-${accept_dns}.log"
    grep -Fx -- "-m bash -c mount --bind \"\$1\" /etc/resolv.conf; shift; exec \"\$@\" _ /run/tailscale/tailscaled-resolv.conf tailscaled --statedir /data --socket ${tmpdir}/socket/tailscaled.sock" "${tmpdir}/unshare-${accept_dns}.log"
  elif grep -Fxq prepare-egress "${tmpdir}/magicdns-${accept_dns}.log"; then
    echo 'FAIL: disabled DNS acceptance started the egress loop-prevention resolver' >&2
    return 1
  fi
  grep -Fx start-ingress "${tmpdir}/magicdns-${accept_dns}.log"
  grep -Fx cleanup "${tmpdir}/magicdns-${accept_dns}.log"
}

# Production break caught: a prepare-egress failure occurs before ownership is
# marked, so the EXIT trap fails to remove partially created resolver state.
: > "${tmpdir}/magicdns-failure.log"
PATH="${tmpdir}/bin:${PATH}" \
  TAILSCALE_SOCKET="${tmpdir}/socket/failed.sock" \
  TAILSCALE_TEST_LOG="${tmpdir}/calls-failure.log" \
  MAGICDNS_RESOLVER="${tmpdir}/bin/magicdns-resolver" \
  MAGICDNS_TEST_LOG="${tmpdir}/magicdns-failure.log" \
  UNSHARE_TEST_LOG="${tmpdir}/unshare-failure.log" \
  FAKE_ACCEPT_DNS=true FAKE_PREPARE_FAIL=true \
  bash "${run_script}" >/dev/null 2>&1 || true
grep -Fx prepare-egress "${tmpdir}/magicdns-failure.log"
grep -Fx cleanup "${tmpdir}/magicdns-failure.log"

# Characterization of the namespace boundary: unshare must receive the exact
# mount/exec contract, and its immediate failure must not run tailscale up.
: > "${tmpdir}/magicdns-unshare-failure.log"
PATH="${tmpdir}/bin:${PATH}" \
  TAILSCALE_SOCKET="${tmpdir}/socket/unshare-failed.sock" \
  TAILSCALE_TEST_LOG="${tmpdir}/calls-unshare-failure.log" \
  MAGICDNS_RESOLVER="${tmpdir}/bin/magicdns-resolver" \
  MAGICDNS_TEST_LOG="${tmpdir}/magicdns-unshare-failure.log" \
  UNSHARE_TEST_LOG="${tmpdir}/unshare-failure.log" \
  FAKE_ACCEPT_DNS=true FAKE_UNSHARE_FAIL=true \
  timeout 2 bash "${run_script}" >/dev/null 2>&1 || true
grep -Fx -- "-m bash -c mount --bind \"\$1\" /etc/resolv.conf; shift; exec \"\$@\" _ /run/tailscale/tailscaled-resolv.conf tailscaled --statedir /data --socket ${tmpdir}/socket/unshare-failed.sock" "${tmpdir}/unshare-failure.log"
[[ ! -s "${tmpdir}/calls-unshare-failure.log" ]] || { echo 'FAIL: tailscale up ran after unshare failed' >&2; exit 1; }
grep -Fx cleanup "${tmpdir}/magicdns-unshare-failure.log"

run_case true
run_case false

# Characterization: the networking additions must not change existing options.
: > "${tmpdir}/calls-existing-options.log"
PATH="${tmpdir}/bin:${PATH}" \
  TAILSCALE_SOCKET="${tmpdir}/socket/existing-options.sock" \
  TAILSCALE_TEST_LOG="${tmpdir}/calls-existing-options.log" \
  MAGICDNS_RESOLVER="${tmpdir}/bin/magicdns-resolver" \
  MAGICDNS_TEST_LOG="${tmpdir}/magicdns-existing-options.log" \
  UNSHARE_TEST_LOG="${tmpdir}/unshare-existing-options.log" \
  FAKE_ACCEPT_DNS=false FAKE_EXISTING_OPTIONS=true \
  timeout 7 bash "${run_script}" >/dev/null 2>&1 || true
grep -Fx -- "--socket ${tmpdir}/socket/existing-options.sock up --reset --accept-dns=false --advertise-exit-node --advertise-connector --advertise-routes 192.0.2.0/24 --advertise-tags tag:existing --hostname existing-host --port 41642" "${tmpdir}/calls-existing-options.log"
grep -Fx -- 'set --webclient=true' "${tmpdir}/calls-existing-options.log"
grep -Fx -- 'serve --bg --https 443 http://localhost:8123' "${tmpdir}/calls-existing-options.log"

printf '%s\n' 'PASS: accept_dns is applied deterministically'
