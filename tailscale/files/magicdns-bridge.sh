#!/usr/bin/env bash
# shellcheck shell=bash

# DNAT Home Assistant DNS queries for Tailscale Quad100 to the local ingress
# resolver. This script deliberately only owns rules with all of these exact
# match conditions, so cleanup cannot affect unrelated NAT configuration.

set -Eeuo pipefail

readonly MAGIC_DNS_IPV4='100.100.100.100'
readonly MAGIC_DNS_IPV6='fd7a:115c:a1e0::53'
readonly HASSIO_BRIDGE='hassio'
readonly DNS_PORT='53'
readonly MAGICDNS_RUNTIME_DIR="${MAGICDNS_RUNTIME_DIR:-/run/tailscale}"
readonly ADDRESS_CACHE="${MAGICDNS_RUNTIME_DIR}/magicdns-bridge-addresses"
TAILSCALE_SOCKET="${TAILSCALE_SOCKET:-/var/run/tailscale/tailscaled.sock}"

ha_dns_ipv4=''
ha_dns_ipv6=''
ha_supervisor_ipv4=''
ha_supervisor_ipv6=''
tailscale_ipv4=''
tailscale_ipv6=''

log() {
  printf '%s\n' "${*}"
}

lookup() {
  local host=$1 family=$2
  dig "${host}.local.hass.io" "${family}" +short | awk 'NF { print; exit }'
}

discover_addresses() {
  ha_dns_ipv4=$(lookup dns A || true)
  ha_dns_ipv6=$(lookup dns AAAA || true)
  ha_supervisor_ipv4=$(lookup supervisor A || true)
  ha_supervisor_ipv6=$(lookup supervisor AAAA || true)
  tailscale_ipv4=$(tailscale --socket "${TAILSCALE_SOCKET}" ip -4 || true)
  tailscale_ipv6=$(tailscale --socket "${TAILSCALE_SOCKET}" ip -6 || true)

  if [[ -z "${tailscale_ipv4}" && -z "${tailscale_ipv6}" ]]; then
    log 'Unable to determine the local Tailscale address for the MagicDNS bridge' >&2
    return 1
  fi
  if [[ -z "${ha_dns_ipv4}${ha_dns_ipv6}${ha_supervisor_ipv4}${ha_supervisor_ipv6}" ]]; then
    log 'Unable to determine Home Assistant DNS or Supervisor addresses for the MagicDNS bridge' >&2
    return 1
  fi
}

save_addresses() {
  mkdir -p "${MAGICDNS_RUNTIME_DIR}"
  printf '%s\n' "${ha_dns_ipv4}" "${ha_dns_ipv6}" "${ha_supervisor_ipv4}" "${ha_supervisor_ipv6}" "${tailscale_ipv4}" "${tailscale_ipv6}" > "${ADDRESS_CACHE}"
}

load_cached_addresses() {
  [[ -r "${ADDRESS_CACHE}" ]] || return 1
  {
    IFS= read -r ha_dns_ipv4
    IFS= read -r ha_dns_ipv6
    IFS= read -r ha_supervisor_ipv4
    IFS= read -r ha_supervisor_ipv6
    IFS= read -r tailscale_ipv4
    IFS= read -r tailscale_ipv6
  } < "${ADDRESS_CACHE}"
}

rule_exists() {
  local tool=$1 source=$2 destination=$3 target=$4 protocol=$5
  "${tool}" -t nat -C PREROUTING -s "${source}" -d "${destination}" -i "${HASSIO_BRIDGE}" -p "${protocol}" --dport "${DNS_PORT}" -j DNAT --to-destination "${target}:${DNS_PORT}"
}

remove_rule() {
  local tool=$1 source=$2 destination=$3 target=$4 protocol=$5
  if rule_exists "${tool}" "${source}" "${destination}" "${target}" "${protocol}"; then
    "${tool}" -t nat -D PREROUTING -s "${source}" -d "${destination}" -i "${HASSIO_BRIDGE}" -p "${protocol}" --dport "${DNS_PORT}" -j DNAT --to-destination "${target}:${DNS_PORT}"
  fi
}

install_rule() {
  local tool=$1 source=$2 destination=$3 target=$4 protocol=$5
  if rule_exists "${tool}" "${source}" "${destination}" "${target}" "${protocol}"; then
    return 0
  fi
  "${tool}" -t nat -A PREROUTING -s "${source}" -d "${destination}" -i "${HASSIO_BRIDGE}" -p "${protocol}" --dport "${DNS_PORT}" -j DNAT --to-destination "${target}:${DNS_PORT}"
}

with_family_rules() {
  local action=$1 tool=$2 destination=$3 target=$4
  shift 4
  local source protocol
  for source in "$@"; do
    [[ -n "${source}" ]] || continue
    for protocol in udp tcp; do
      "${action}_rule" "${tool}" "${source}" "${destination}" "${target}" "${protocol}"
    done
  done
}

cleanup() {
  if ! discover_addresses; then
    load_cached_addresses || return 0
  fi
  with_family_rules remove iptables "${MAGIC_DNS_IPV4}" "${tailscale_ipv4}" "${ha_dns_ipv4}" "${ha_supervisor_ipv4}"
  with_family_rules remove ip6tables "${MAGIC_DNS_IPV6}" "[${tailscale_ipv6}]" "${ha_dns_ipv6}" "${ha_supervisor_ipv6}"
  rm -f "${ADDRESS_CACHE}"
}

setup() {
  discover_addresses
  save_addresses
  if ! with_family_rules install iptables "${MAGIC_DNS_IPV4}" "${tailscale_ipv4}" "${ha_dns_ipv4}" "${ha_supervisor_ipv4}" || \
    ! with_family_rules install ip6tables "${MAGIC_DNS_IPV6}" "[${tailscale_ipv6}]" "${ha_dns_ipv6}" "${ha_supervisor_ipv6}"; then
    log 'MagicDNS bridge setup failed; removing partial forwarding state' >&2
    cleanup || true
    return 1
  fi
}

guidance() {
  local configured_server
  for configured_server in $(bashio::dns.servers); do
    if [[ "${configured_server}" == "dns://${MAGIC_DNS_IPV4}" || "${configured_server}" == "dns://${MAGIC_DNS_IPV6}" ]]; then
      return 0
    fi
  done
  log "MagicDNS is not configured for Home Assistant. Run: ha dns options --servers dns://${MAGIC_DNS_IPV4}"
  log 'To undo it later, run: ha dns reset && ha dns restart'
}

case "${1:-}" in
  setup) setup ;;
  cleanup) cleanup ;;
  guidance) guidance ;;
  *)
    printf 'Usage: %s {setup|cleanup|guidance}\n' "${0##*/}" >&2
    exit 2
    ;;
esac
