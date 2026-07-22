#!/usr/bin/env bash

# Exercise the public managed setup path against one already-authenticated
# hive-web archive. The caller owns release-signature verification; this helper
# pins the exact digest again, confines every write, substitutes inert service
# managers, and proves `hive setup --no-init --yes --json` installs those bytes.

set -euo pipefail

HIVE_BIN=""
WEB_ARCHIVE=""
WEB_SHA256=""
PREFIX=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hive-bin=*) HIVE_BIN="${1#*=}" ;;
    --archive=*) WEB_ARCHIVE="${1#*=}" ;;
    --sha256=*) WEB_SHA256="${1#*=}" ;;
    --prefix=*) PREFIX="${1#*=}" ;;
    *) echo "verify-managed-web-setup: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

[[ -x "$HIVE_BIN" ]] || { echo "verify-managed-web-setup: --hive-bin must be executable" >&2; exit 2; }
[[ -f "$WEB_ARCHIVE" ]] || { echo "verify-managed-web-setup: --archive must be a file" >&2; exit 2; }
[[ "$WEB_SHA256" =~ ^[0-9a-fA-F]{64}$ ]] || {
  echo "verify-managed-web-setup: --sha256 must be an exact SHA-256 digest" >&2
  exit 2
}
[[ -n "$PREFIX" ]] || { echo "verify-managed-web-setup: --prefix is required" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "verify-managed-web-setup: jq is required" >&2; exit 3; }
command -v ruby >/dev/null 2>&1 || { echo "verify-managed-web-setup: ruby is required" >&2; exit 3; }
BUNDLER_RUBYLIB="$(ruby -rrubygems -e '
  print Gem::Specification.find_by_name("bundler").full_require_paths.join(File::PATH_SEPARATOR)
' 2>/dev/null || true)"
[[ -n "$BUNDLER_RUBYLIB" ]] || { echo "verify-managed-web-setup: bundler library is required" >&2; exit 3; }
BUNDLER_EXECUTABLE_SOURCE="$(ruby -rrubygems -e '
  spec = Gem::Specification.find_by_name("bundler")
  print File.join(spec.full_gem_path, "exe", "bundle")
' 2>/dev/null || true)"
[[ -f "$BUNDLER_EXECUTABLE_SOURCE" ]] || {
  echo "verify-managed-web-setup: Bundler executable source is required" >&2
  exit 3
}

HIVE_BIN="$(cd "$(dirname "$HIVE_BIN")" && pwd)/$(basename "$HIVE_BIN")"
WEB_ARCHIVE="$(cd "$(dirname "$WEB_ARCHIVE")" && pwd)/$(basename "$WEB_ARCHIVE")"
PREFIX="$(mkdir -p "$PREFIX" && cd "$PREFIX" && pwd)"

if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL_SHA256="$(sha256sum "$WEB_ARCHIVE" | awk '{print $1}')"
else
  ACTUAL_SHA256="$(shasum -a 256 "$WEB_ARCHIVE" | awk '{print $1}')"
fi
ACTUAL_SHA256="$(printf '%s' "$ACTUAL_SHA256" | tr '[:upper:]' '[:lower:]')"
WEB_SHA256="$(printf '%s' "$WEB_SHA256" | tr '[:upper:]' '[:lower:]')"
[[ "$ACTUAL_SHA256" == "$WEB_SHA256" ]] || {
  echo "verify-managed-web-setup: archive digest mismatch" >&2
  exit 1
}
SANDBOX="$(mktemp -d "${PREFIX%/}/managed-web-setup.XXXXXX")"
SERVICE_MANAGER_BIN="$SANDBOX/service-manager-bin"
mkdir -p "$SERVICE_MANAGER_BIN" "$SANDBOX/home" "$SANDBOX/hive-home" "$SANDBOX/work"

case "$(uname -s)" in
  Linux)
    printf '%s\n' '#!/bin/sh' 'exit 0' > "$SERVICE_MANAGER_BIN/systemctl"
    chmod 0755 "$SERVICE_MANAGER_BIN/systemctl"
    SERVICE_MANAGER_COMMAND="systemctl"
    ;;
  Darwin)
    # The generated stub expands its own positional argument when launchctl
    # invokes it; the outer verifier must preserve the expression literally.
    # shellcheck disable=SC2016
    printf '%s\n' \
      '#!/bin/sh' \
      'if [ "${1:-}" = "print" ]; then printf "%s\n" "state = running"; fi' \
      'exit 0' > "$SERVICE_MANAGER_BIN/launchctl"
    chmod 0755 "$SERVICE_MANAGER_BIN/launchctl"
    SERVICE_MANAGER_COMMAND="launchctl"
    ;;
  *)
    echo "verify-managed-web-setup: managed services require Linux or macOS" >&2
    exit 3
    ;;
esac

# These probes must be hermetic too. qmd/sqlite are reported as available;
# native agent and gh probes fail without consulting operator credentials or
# starting a CLI that may initialize state. Setup still proceeds because the
# explicit --yes boundary has been crossed, and the relevant release proof is
# the web/service phase chain below.
for command_name in qmd sqlite3; do
  printf '%s\n' '#!/bin/sh' 'exit 0' > "$SERVICE_MANAGER_BIN/$command_name"
  chmod 0755 "$SERVICE_MANAGER_BIN/$command_name"
done
for command_name in claude codex pi gh; do
  printf '%s\n' '#!/bin/sh' 'exit 1' > "$SERVICE_MANAGER_BIN/$command_name"
  chmod 0755 "$SERVICE_MANAGER_BIN/$command_name"
done

# The candidate gem wrapper intentionally replaces GEM_HOME/GEM_PATH. A normal
# RubyGems-generated `bundle` launcher would therefore lose the Bundler gem it
# was generated for. Invoke Bundler's source through the already-resolved Ruby
# and load path so the web install remains hermetic under candidate isolation.
RUBY_EXECUTABLE="$(command -v ruby)"
{
  printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
  printf 'exec %q -I%q %q "$@"\n' \
    "$RUBY_EXECUTABLE" "$BUNDLER_RUBYLIB" "$BUNDLER_EXECUTABLE_SOURCE"
} > "$SERVICE_MANAGER_BIN/bundle"
chmod 0755 "$SERVICE_MANAGER_BIN/bundle"
{
  printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
  printf 'exec %q -I%q "$@"\n' "$RUBY_EXECUTABLE" "$BUNDLER_RUBYLIB"
} > "$SERVICE_MANAGER_BIN/ruby"
chmod 0755 "$SERVICE_MANAGER_BIN/ruby"

RUBY_BIN_DIR="$(dirname "$(command -v ruby)")"
SAFE_PATH="$SERVICE_MANAGER_BIN:$RUBY_BIN_DIR:/usr/local/bin:/usr/bin:/bin"
RESOLVED_SERVICE_MANAGER="$(PATH="$SAFE_PATH" command -v "$SERVICE_MANAGER_COMMAND")"
[[ "$RESOLVED_SERVICE_MANAGER" == "$SERVICE_MANAGER_BIN/$SERVICE_MANAGER_COMMAND" ]] || {
  echo "verify-managed-web-setup: failed to isolate $SERVICE_MANAGER_COMMAND" >&2
  exit 3
}

PORT_FILE="$SANDBOX/health-port"
ruby -rsocket -rjson -e '
  server = TCPServer.new("127.0.0.1", 0)
  File.write(ARGV.fetch(0), server.addr.fetch(1).to_s)
  loop do
    socket = server.accept
    while (line = socket.gets)
      break if line == "\r\n"
    end
    body = JSON.generate("ok" => true)
    socket.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
    socket.close
  end
' "$PORT_FILE" >"$SANDBOX/health.log" 2>&1 &
HEALTH_PID=$!

cleanup() {
  kill "$HEALTH_PID" >/dev/null 2>&1 || true
  wait "$HEALTH_PID" 2>/dev/null || true
}
trap cleanup EXIT

for _attempt in $(seq 1 100); do
  [[ -s "$PORT_FILE" ]] && break
  kill -0 "$HEALTH_PID" >/dev/null 2>&1 || {
    cat "$SANDBOX/health.log" >&2
    exit 1
  }
  sleep 0.05
done
[[ -s "$PORT_FILE" ]] || { echo "verify-managed-web-setup: health fixture did not start" >&2; exit 1; }
HEALTH_PORT="$(cat "$PORT_FILE")"

cat > "$SANDBOX/hive-home/config.yml" <<YAML
web:
  bind: 127.0.0.1
  port: ${HEALTH_PORT}
YAML

SETUP_JSON="$SANDBOX/setup.json"
SETUP_ERR="$SANDBOX/setup.err"
set +e
(
  cd "$SANDBOX/work"
  HOME="$SANDBOX/home" \
  HIVE_HOME="$SANDBOX/hive-home" \
  XDG_BIN_HOME="$SANDBOX/bin" \
  XDG_CONFIG_HOME="$SANDBOX/config" \
  XDG_DATA_HOME="$SANDBOX/data" \
  XDG_STATE_HOME="$SANDBOX/state" \
  XDG_CACHE_HOME="$SANDBOX/cache" \
  CLAUDE_CONFIG_DIR="$SANDBOX/home/.claude" \
  CODEX_HOME="$SANDBOX/home/.codex" \
  PI_CODING_AGENT_DIR="$SANDBOX/home/.pi/agent" \
  ANTHROPIC_API_KEY='' CLAUDE_API_KEY='' OPENAI_API_KEY='' \
  RUBYLIB="$BUNDLER_RUBYLIB" \
  PATH="$SAFE_PATH" \
  HIVE_WEB_BUNDLE_URL="$WEB_ARCHIVE" \
  HIVE_WEB_BUNDLE_SHA256="$WEB_SHA256" \
    "$HIVE_BIN" setup --no-init --yes --json >"$SETUP_JSON" 2>"$SETUP_ERR"
)
SETUP_RC=$?
set -e

if ! jq -e '.schema == "hive-setup" and .mode == "managed_service"' "$SETUP_JSON" >/dev/null; then
  cat "$SETUP_JSON" "$SETUP_ERR" >&2 2>/dev/null || true
  echo "verify-managed-web-setup: setup did not emit the managed hive-setup envelope" >&2
  exit 1
fi

if ! jq -e '
  [.phases[] | select(.name == "agent_skills")] as $rows |
  ($rows | length) == 1 and
  ($rows[0].classification != "consent_required") and
  ($rows[0].classification != "refused")
' "$SETUP_JSON" >/dev/null; then
  cat "$SETUP_JSON" "$SETUP_ERR" >&2 2>/dev/null || true
  echo "verify-managed-web-setup: setup did not cross the explicit consent boundary" >&2
  exit 1
fi

for phase in web_bundle daemon_service web_service web; do
  if ! jq -e --arg phase "$phase" '
    [.phases[] | select(.name == $phase)] as $rows |
    ($rows | length) == 1 and $rows[0].ok == true
  ' "$SETUP_JSON" >/dev/null; then
    cat "$SETUP_JSON" "$SETUP_ERR" >&2 2>/dev/null || true
    echo "verify-managed-web-setup: managed setup phase failed: $phase" >&2
    exit 1
  fi
done

PAYLOAD_OK="$(jq -r '.ok | tostring' "$SETUP_JSON")"
if [[ "$PAYLOAD_OK" == "true" && "$SETUP_RC" -ne 0 ]] || \
   [[ "$PAYLOAD_OK" == "false" && "$SETUP_RC" -eq 0 ]]; then
  echo "verify-managed-web-setup: setup exit code disagrees with the JSON envelope" >&2
  exit 1
fi

[[ -f "$SANDBOX/hive-home/web/config/application.rb" ]] || {
  echo "verify-managed-web-setup: managed web app was not extracted" >&2
  exit 1
}
[[ -s "$SANDBOX/hive-home/web/.hive-web-version" ]] || {
  echo "verify-managed-web-setup: managed web version stamp is missing" >&2
  exit 1
}

case "$(uname -s)" in
  Linux)
    [[ -f "$SANDBOX/home/.config/systemd/user/hive-daemon.service" ]]
    [[ -f "$SANDBOX/home/.config/systemd/user/hive-web.service" ]]
    ;;
  Darwin)
    [[ -f "$SANDBOX/home/Library/LaunchAgents/local.hive-daemon.plist" ]]
    [[ -f "$SANDBOX/home/Library/LaunchAgents/local.hive-web.plist" ]]
    ;;
esac

printf 'managed web setup verified from %s (sha256=%s)\n' "$WEB_ARCHIVE" "$WEB_SHA256"
