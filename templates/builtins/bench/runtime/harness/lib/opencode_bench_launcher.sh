#!/usr/bin/env bash
# Hive stays root in sealed benchmark containers so it can read its protected
# control bundle. Every real OpenCode process crosses this launcher and drops
# to the unprivileged candidate identity before it can inspect the filesystem.
set -uo pipefail

REAL_OPENCODE="${HB_OPENCODE_REAL_BIN:-/usr/local/bin/opencode}"

if [ "${HB_SEALED_AGENT_RUNTIME:-0}" != "1" ]; then
  exec "$REAL_OPENCODE" "$@"
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "opencode benchmark launcher: sealed mode requires the root controller" >&2
  exit 1
fi

candidate_uid="${HB_CANDIDATE_UID:-1000}"
candidate_gid="${HB_CANDIDATE_GID:-1000}"
chown -R "$candidate_uid:$candidate_gid" /work 2>/dev/null || {
  echo "opencode benchmark launcher: cannot hand the worktree to the candidate user" >&2
  exit 1
}

exec setpriv --reuid="$candidate_uid" --regid="$candidate_gid" --init-groups \
  --bounding-set=-all --inh-caps=-all --ambient-caps=-all \
  env -u BUNDLE_GEMFILE \
    GEM_HOME=/usr/local/bundle \
    GEM_PATH=/usr/local/bundle:/usr/local/lib/ruby/gems/3.4.0 \
    PATH=/usr/local/bin:/usr/bin:/bin \
    "$REAL_OPENCODE" "$@"
