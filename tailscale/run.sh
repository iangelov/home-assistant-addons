#!/usr/bin/with-contenv bashio
# shellcheck shell=bash

set -Eeum -o pipefail

TAILSCALE_SOCKET="/var/run/tailscale/tailscaled.sock"
TAILSCALE_FLAGS=()
TAILSCALE_SET_FLAGS=()
TAILSCALED_FLAGS=("--statedir" "/data" "--socket" "${TAILSCALE_SOCKET}")
PROXY_SERVE_HA=false

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
  trap 'rm -f "$AUTH_KEY_FILE"' EXIT
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

tailscaled -cleanup "${TAILSCALED_FLAGS[@]}"
tailscaled "${TAILSCALED_FLAGS[@]}" &

i=0
while [[ $i -lt 12 ]]; do
  if [[ -e "$TAILSCALE_SOCKET" ]]; then
    # bring up the tunnel
    tailscale --socket "$TAILSCALE_SOCKET" up --reset "${TAILSCALE_FLAGS[@]}"

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
