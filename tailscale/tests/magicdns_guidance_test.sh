#!/usr/bin/env bash
# shellcheck shell=bash
set -Eeuo pipefail

# Production break caught: a missing Quad100 Supervisor DNS configuration is
# silent, or the add-on attempts to mutate Supervisor DNS settings itself.

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
bridge_script="${repo_root}/tailscale/files/magicdns-bridge.sh"
tmpdir=$(mktemp -d)
trap 'rm -rf "${tmpdir}"' EXIT
mkdir -p "${tmpdir}/bin"

printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "${tmpdir}/bin/bashio::dns.servers"
printf '%s\n' '#!/usr/bin/env bash' 'echo "FAIL: add-on must not call ha dns" >&2; exit 99' > "${tmpdir}/bin/ha"
chmod +x "${tmpdir}/bin/bashio::dns.servers" "${tmpdir}/bin/ha"

output=$(PATH="${tmpdir}/bin:${PATH}" bash "${bridge_script}" guidance)
case "${output}" in
  *'ha dns options --servers dns://100.100.100.100'*'ha dns reset && ha dns restart'*) ;;
  *)
    printf 'FAIL: expected actionable non-mutating MagicDNS guidance, got: %s\n' "${output}" >&2
    exit 1
    ;;
esac

printf '%s\n' 'PASS: missing HA DNS configuration is explained without mutation'
