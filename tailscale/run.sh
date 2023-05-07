#!/usr/bin/with-contenv bashio
# shellcheck shell=bash

set -eum

# CONFIG_PATH="/data/options.json"
TAILSCALE_SOCKET="/var/run/tailscale/tailscaled.sock"
TAILSCALE_FLAGS=()
TAILSCALED_FLAGS=("--statedir" "/data" "--state" "/data/tailscaled.state" "--socket" "${TAILSCALE_SOCKET}")

if bashio::config.has_value 'advertise_exit_node'; then
  if bashio::config.true 'advertise_exit_node'; then
    TAILSCALE_FLAGS+=("--advertise-exit-node")
  fi
fi

if bashio::config.has_value 'advertised_routes'; then
  routes=""
  for route in $(bashio::config 'advertised_routes'); do
    routes+="${route},"
  done
   # shellcheck disable=SC2001
  TAILSCALE_FLAGS+=('--advertise-routes' "$(echo "$routes" | sed 's/,\s*$//')")
fi

if bashio::config.has_value 'auth_key'; then
  TAILSCALE_FLAGS+=('--authkey' "$(bashio::config 'auth_key')")
fi

if bashio::config.has_value 'force_reauth'; then
  if bashio::config.true 'force_reauth'; then
    TAILSCALE_FLAGS+=('--force-reauth')
  fi
fi

if bashio::config.has_value 'hostname'; then
  TAILSCALE_FLAGS+=('--hostname' "$(bashio::config 'hostname')")
fi

if bashio::config.has_value 'port'; then
  TAILSCALE_FLAGS+=('--port' "$(bashio::config 'port')")
fi

if bashio::config.has_value 'hostname' && bashio::config.has_value 'certificate_domain'; then
  TAILSCALE_CERTIFICATE_FQDN="$(bashio::config 'hostname').$(bashio::config 'certificate_domain')"
fi

tailscaled -cleanup "${TAILSCALED_FLAGS[@]}"
tailscaled "${TAILSCALED_FLAGS[@]}" &

i=0
while test $i -lt 12; do
  if test -e "$TAILSCALE_SOCKET"; then
    # bring up the tunnel
    tailscale --socket "$TAILSCALE_SOCKET" up "${TAILSCALE_FLAGS[@]}"
    if ! test -z "$TAILSCALE_CERTIFICATE_FQDN"; then
      tailscale cert --cert-file /ssl/fullchain.pem --key-file /ssl/privkey.pem "$TAILSCALE_CERTIFICATE_FQDN"
    fi
    # put Tailscale in foreground
    fg
    exit $?
  else
    i+=1
    echo "tailscaled hasn't started yet, sleeping for 5 seconds..."
    sleep 5
  fi
done

echo "Unable to start tailscaled"
exit 1
