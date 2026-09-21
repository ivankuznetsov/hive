#!/usr/bin/env bash
# Keep the required Pi version preflight deterministic under highly parallel
# benchmark load. The installed npm package is the version source of truth;
# every non-version invocation delegates to the real Pi CLI with the packaged
# transport extension in front of Hive's own arguments.
set -uo pipefail

REAL_PI="${HB_PI_REAL_BIN:-/usr/local/bin/pi}"
PACKAGE_JSON="${HB_PI_PACKAGE_JSON:-/usr/local/lib/node_modules/@earendil-works/pi-coding-agent/package.json}"
TOOL_STREAM="${HB_PI_TOOL_STREAM:-/opt/hb/pi-tool-stream.ts}"

if [ "$#" -eq 1 ] && [ "$1" = "--version" ]; then
  version="$(sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$PACKAGE_JSON" | head -1)"
  if [ -z "$version" ]; then
    echo "pi benchmark launcher: cannot read installed Pi version" >&2
    exit 1
  fi
  printf '%s\n' "$version"
  exit 0
fi

if [ ! -f "$TOOL_STREAM" ]; then
  echo "pi benchmark launcher: tool-stream extension is missing: $TOOL_STREAM" >&2
  exit 1
fi
PI_ARGS=(--extension "$TOOL_STREAM" "$@")

if [ "${HB_SEALED_AGENT_RUNTIME:-0}" = "1" ]; then
  if [ "$(id -u)" -ne 0 ]; then
    echo "pi benchmark launcher: sealed mode requires the root controller" >&2
    exit 1
  fi
  candidate_uid="${HB_CANDIDATE_UID:-1000}"
  candidate_gid="${HB_CANDIDATE_GID:-1000}"
  chown -R "$candidate_uid:$candidate_gid" /work "$HOME/.pi" 2>/dev/null || {
    echo "pi benchmark launcher: cannot hand the worktree to the candidate user" >&2
    exit 1
  }
  exec setpriv --reuid="$candidate_uid" --regid="$candidate_gid" --init-groups \
    --bounding-set=-all --inh-caps=-all --ambient-caps=-all \
    env -u BUNDLE_GEMFILE \
      GEM_HOME=/usr/local/bundle \
      GEM_PATH=/usr/local/bundle:/usr/local/lib/ruby/gems/3.4.0 \
      PATH=/usr/local/bin:/usr/bin:/bin \
      "$REAL_PI" "${PI_ARGS[@]}"
fi

exec "$REAL_PI" "${PI_ARGS[@]}"
