#!/usr/bin/env bash
set -Eeuo pipefail

# Production break caught: an add-on change keeps the old version or pretends
# the bundled upstream Tailscale binary changed.
version=$(yq -r '.version' tailscale/config.yaml)
binary=$(sed -nE 's/^ARG TAILSCALE_VERSION="v([^"]+)"/\1/p' tailscale/Dockerfile)
[[ "${version}" == 'v1.102.1.1' ]] || { printf 'FAIL: expected add-on revision v1.102.1.1, got %s\n' "${version}" >&2; exit 1; }
[[ "${binary}" == '1.102.1' ]] || { printf 'FAIL: expected upstream binary 1.102.1, got %s\n' "${binary}" >&2; exit 1; }
printf '%s\n' 'PASS: add-on revision advances without changing Tailscale binary version'
