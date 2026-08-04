#!/usr/bin/with-contenv bashio
# shellcheck shell=bash

set -Eeum -o pipefail

TAILSCALE_SOCKET="${TAILSCALE_SOCKET:-/var/run/tailscale/tailscaled.sock}"
MAGICDNS_RESOLVER="${MAGICDNS_RESOLVER:-/magicdns-resolver.sh}"
MAGICDNS_RUNTIME_DIR="${MAGICDNS_RUNTIME_DIR:-/run/tailscale}"
TAILSCALE_FLAGS=()
TAILSCALE_SET_FLAGS=()
TAILSCALED_FLAGS=("--statedir" "/data" "--socket" "${TAILSCALE_SOCKET}")
PROXY_SERVE_HA=false
ACCEPT_DNS=false
MAGICDNS_ACTIVE=false
AUTH_KEY_FILE=''

run_magicdns() {
  ACCEPT_DNS="${ACCEPT_DNS}" MAGICDNS_RUNTIME_DIR="${MAGICDNS_RUNTIME_DIR}" "${MAGICDNS_RESOLVER}" "$@"
}

# shellcheck disable=SC2329 # Invoked through the EXIT trap below.
cleanup() {
  local status=$?
  if [[ "${MAGICDNS_ACTIVE}" == true ]]; then
    run_magicdns cleanup || true
  fi
  [[ -z "${AUTH_KEY_FILE}" ]] || rm -f "${AUTH_KEY_FILE}"
  return "${status}"
}
trap cleanup EXIT

if bashio::config.true 'accept_dns'; then
  ACCEPT_DNS=true
  TAILSCALE_FLAGS+=("--accept-dns=true")
else
  TAILSCALE_FLAGS+=("--accept-dns=false")
fi

if bashio::config.true 'advertise_exit_node'; then
  TAILSCALE_FLAGS+=("--advertise-exit-node")
fi

if bashio::config.true 'advertise_connector'; then
  TAILSCALE_FLAGS+=("--advertise-connector")
fi

if bashio::config.has_value 'advertised_routes'; then
  routes=$(bashio::config 'advertised_routes' | tr '\n' ',' | sed 's/,$//')
  TAILSCALE_FLAGS+=('--advertise-routes' "$routes")
fi

if bashio::config.has_value 'tags'; then
  tags=$(bashio::config 'tags' | tr '\n' ',' | sed 's/,$//')
  TAILSCALE_FLAGS+=('--advertise-tags' "$tags")
fi

if bashio::config.has_value 'auth_key'; then
  # Pass the auth key via a file so it never appears in /proc/<pid>/cmdline.
  AUTH_KEY_FILE=$(mktemp)
  printf '%s' "$(bashio::config 'auth_key')" > "$AUTH_KEY_FILE"
  TAILSCALE_FLAGS+=('--authkey' "file:${AUTH_KEY_FILE}")
fi

if bashio::config.true 'force_reauth'; then
  TAILSCALE_FLAGS+=('--force-reauth')
fi

if bashio::config.has_value 'hostname'; then
  TAILSCALE_FLAGS+=('--hostname' "$(bashio::config 'hostname')")
fi

if bashio::config.has_value 'port'; then
  TAILSCALE_FLAGS+=('--port' "$(bashio::config 'port')")
fi

if bashio::config.true 'proxy_serve_ha'; then
  PROXY_SERVE_HA=true
fi

if bashio::config.true 'webclient'; then
  TAILSCALE_SET_FLAGS+=('--webclient=true')
fi

MAGICDNS_ACTIVE=true
run_magicdns setup-drop
if [[ "${ACCEPT_DNS}" == true ]]; then
  run_magicdns prepare-egress
fi

tailscaled -cleanup "${TAILSCALED_FLAGS[@]}"
if [[ "${ACCEPT_DNS}" == true ]]; then
  # Only tailscaled receives the private resolver view. This prevents Quad100
  # from recursing through Home Assistant DNS while preserving host DNS.
  # shellcheck disable=SC2016 # $1 and $@ expand in the isolated shell.
  unshare -m bash -c 'mount --bind "$1" /etc/resolv.conf; shift; exec "$@"' _ \
    "${MAGICDNS_RUNTIME_DIR}/tailscaled-resolv.conf" tailscaled "${TAILSCALED_FLAGS[@]}" &
else
  tailscaled "${TAILSCALED_FLAGS[@]}" &
fi

i=0
while [[ $i -lt 12 ]]; do
  if [[ -e "$TAILSCALE_SOCKET" ]]; then
    # bring up the tunnel
    tailscale --socket "$TAILSCALE_SOCKET" up --reset "${TAILSCALE_FLAGS[@]}"
    run_magicdns start-ingress
    run_magicdns guidance

    if [[ ${#TAILSCALE_SET_FLAGS[@]} -gt 0 ]]; then
      tailscale set "${TAILSCALE_SET_FLAGS[@]}"
    fi

    if [[ "$PROXY_SERVE_HA" == true ]]; then
      tailscale serve --bg --https 443 http://localhost:8123
    else
      # Clear any serve config left over from a previous run with proxy_serve_ha=true.
      tailscale serve reset 2>/dev/null || true
    fi

    # put Tailscale in foreground
    fg
    exit
  else
    (( i+=1 ))
    echo "tailscaled hasn't started yet, sleeping for 5 seconds..."
    sleep 5
  fi
done

echo "Unable to start tailscaled"
exit 1
