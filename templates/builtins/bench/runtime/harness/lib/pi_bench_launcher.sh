#!/usr/bin/env bash
# Keep the required Pi version preflight deterministic under highly parallel
# benchmark load. The installed npm package is the version source of truth;
# every non-version invocation delegates byte-for-byte to the real Pi CLI.
set -uo pipefail

REAL_PI="${HB_PI_REAL_BIN:-/usr/local/bin/pi}"
PACKAGE_JSON="${HB_PI_PACKAGE_JSON:-/usr/local/lib/node_modules/@earendil-works/pi-coding-agent/package.json}"

if [ "$#" -eq 1 ] && [ "$1" = "--version" ]; then
  version="$(sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$PACKAGE_JSON" | head -1)"
  if [ -z "$version" ]; then
    echo "pi benchmark launcher: cannot read installed Pi version" >&2
    exit 1
  fi
  printf '%s\n' "$version"
  exit 0
fi

exec "$REAL_PI" "$@"
