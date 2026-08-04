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
[[ "${1}" == "accept_dns" && "${FAKE_ACCEPT_DNS}" == true ]]
'
make_fake 'bashio::config.has_value' 'exit 1'
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
'
# shellcheck disable=SC2016 # The generated fake expands variables at runtime.
make_fake unshare '
: > "${TAILSCALE_SOCKET}"
sleep 0.01
'

run_case() {
  local accept_dns=$1
  : > "${tmpdir}/calls-${accept_dns}.log"
  PATH="${tmpdir}/bin:${PATH}" \
    TAILSCALE_SOCKET="${tmpdir}/socket/tailscaled.sock" \
    TAILSCALE_TEST_LOG="${tmpdir}/calls-${accept_dns}.log" \
    MAGICDNS_RESOLVER="${tmpdir}/bin/magicdns-resolver" \
    MAGICDNS_TEST_LOG="${tmpdir}/magicdns-${accept_dns}.log" \
    FAKE_ACCEPT_DNS="${accept_dns}" \
    timeout 7 bash "${run_script}" >/dev/null 2>&1 || true
  if ! grep -Fx -- "--socket ${tmpdir}/socket/tailscaled.sock up --reset --accept-dns=${accept_dns}" \
    "${tmpdir}/calls-${accept_dns}.log"; then
    printf 'FAIL: expected deterministic --accept-dns=%s tailscale up invocation\n' "${accept_dns}" >&2
    return 1
  fi
  if [[ "${accept_dns}" == true ]]; then
    grep -Fx prepare-egress "${tmpdir}/magicdns-${accept_dns}.log"
  elif grep -Fxq prepare-egress "${tmpdir}/magicdns-${accept_dns}.log"; then
    echo 'FAIL: disabled DNS acceptance started the egress loop-prevention resolver' >&2
    return 1
  fi
  grep -Fx start-ingress "${tmpdir}/magicdns-${accept_dns}.log"
  grep -Fx cleanup "${tmpdir}/magicdns-${accept_dns}.log"
}

run_case true
run_case false

printf '%s\n' 'PASS: accept_dns is applied deterministically'
