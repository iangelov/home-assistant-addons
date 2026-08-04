#!/usr/bin/env bash
# shellcheck shell=bash
# Portions adapted from hassio-addons/app-tailscale.
# Copyright (c) Franck Nijhof. Licensed under the MIT License.

# Keep the DNS path acyclic in kernel-TUN mode. The egress resolver is visible
# only to tailscaled; the ingress resolver accepts Quad100 traffic DNATed from
# the hassio bridge and passes it to Tailscale's MagicDNS listener.

set -Eeuo pipefail

readonly MAGIC_DNS_IPV4='100.100.100.100'
readonly EGRESS_ADDRESS='127.100.100.100'
readonly DNS_PORT='53'
readonly MAGICDNS_RUNTIME_DIR="${MAGICDNS_RUNTIME_DIR:-/run/tailscale}"
readonly EGRESS_PID="${MAGICDNS_RUNTIME_DIR}/magicdns-egress.pid"
readonly INGRESS_PID="${MAGICDNS_RUNTIME_DIR}/magicdns-ingress.pid"
readonly RESOLV_CONF="${MAGICDNS_RUNTIME_DIR}/tailscaled-resolv.conf"
readonly MAGICDNS_BRIDGE="${MAGICDNS_BRIDGE:-/magicdns-bridge.sh}"
readonly ACCEPT_DNS="${ACCEPT_DNS:-true}"
readonly -a LOOP_BREAK_DOMAINS=(controlplane.tailscale.com log.tailscale.com acme-v02.api.letsencrypt.org)

lookup_ha_dns() {
  dig dns.local.hass.io A +short | awk 'NF { print; exit }'
}

start_dnsmasq() {
  local pidfile=$1
  shift
  dnsmasq "$@" &
  local pid=$!
  printf '%s\n' "${pid}" > "${pidfile}"
  local _
  for _ in 1 2 3 4 5; do
    sleep 0.1
    if ! kill -0 "${pid}" 2>/dev/null; then
      wait "${pid}" 2>/dev/null || true
      rm -f "${pidfile}"
      return 1
    fi
  done
}

prepare_egress() {
  [[ "${ACCEPT_DNS}" == true ]] || return 0
  local ha_dns
  ha_dns=$(lookup_ha_dns)
  [[ -n "${ha_dns}" ]] || { echo 'Unable to resolve Home Assistant DNS for MagicDNS egress' >&2; return 1; }
  mkdir -p "${MAGICDNS_RUNTIME_DIR}"
  local -a options=(--no-hosts --no-resolv --conf-file=/dev/null --keep-in-foreground --log-facility=- --cache-size=0 --bind-dynamic "--port=${DNS_PORT}")
  options+=("--listen-address=${EGRESS_ADDRESS}" '--address=/#/')
  local domain
  for domain in "${LOOP_BREAK_DOMAINS[@]}"; do
    options+=("--server=/${domain}/${ha_dns}")
  done
  if ! start_dnsmasq "${EGRESS_PID}" "${options[@]}"; then
    rm -f "${RESOLV_CONF}"
    return 1
  fi
  printf 'nameserver %s\n' "${EGRESS_ADDRESS}" > "${RESOLV_CONF}"
}

tailnet_suffix() {
  tailscale status --json --peers=false --self=false | sed -nE 's/.*"MagicDNSSuffix"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -n 1
}

start_ingress() {
  mkdir -p "${MAGICDNS_RUNTIME_DIR}"
  local -a options=(--no-hosts --no-resolv --conf-file=/dev/null --keep-in-foreground --log-facility=- --cache-size=0 --bind-dynamic "--port=${DNS_PORT}")
  local tailscale_ipv4 tailscale_ipv6
  tailscale_ipv4=$(tailscale ip -4 || true)
  tailscale_ipv6=$(tailscale ip -6 || true)
  [[ -n "${tailscale_ipv4}${tailscale_ipv6}" ]] || { echo 'Unable to determine the local Tailscale address for MagicDNS ingress' >&2; return 1; }
  [[ -z "${tailscale_ipv4}" ]] || options+=("--listen-address=${tailscale_ipv4}")
  [[ -z "${tailscale_ipv6}" ]] || options+=("--listen-address=${tailscale_ipv6}")
  if [[ "${ACCEPT_DNS}" == true ]]; then
    options+=("--server=${MAGIC_DNS_IPV4}")
    local domain
    for domain in "${LOOP_BREAK_DOMAINS[@]}"; do
      options+=("--server=/${domain}/")
    done
  else
    local suffix
    suffix=$(tailnet_suffix)
    [[ -n "${suffix}" ]] || { echo 'Unable to determine the tailnet MagicDNS suffix' >&2; return 1; }
    options+=('--address=/#/' "--server=/${suffix}/${MAGIC_DNS_IPV4}")
  fi
  if ! start_dnsmasq "${INGRESS_PID}" "${options[@]}"; then
    return 1
  fi
  if ! "${MAGICDNS_BRIDGE}" setup; then
    cleanup
    return 1
  fi
}

stop_pid() {
  local pidfile=$1 pid
  [[ -r "${pidfile}" ]] || return 0
  pid=$(<"${pidfile}")
  kill "${pid}" 2>/dev/null || true
  wait "${pid}" 2>/dev/null || true
  rm -f "${pidfile}"
}

cleanup() {
  "${MAGICDNS_BRIDGE}" setup-drop || true
  "${MAGICDNS_BRIDGE}" cleanup || true
  stop_pid "${INGRESS_PID}"
  stop_pid "${EGRESS_PID}"
  rm -f "${RESOLV_CONF}"
  "${MAGICDNS_BRIDGE}" remove-drop || true
}

case "${1:-}" in
  prepare-egress) prepare_egress ;;
  start-ingress) start_ingress ;;
  setup-drop) "${MAGICDNS_BRIDGE}" setup-drop ;;
  cleanup) cleanup ;;
  *)
    printf 'Usage: %s {prepare-egress|start-ingress|setup-drop|cleanup}\n' "${0##*/}" >&2
    exit 2
    ;;
esac
