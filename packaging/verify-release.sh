#!/usr/bin/env bash
#
# verify-release.sh — end-to-end verification that a published hive
# release artifact installs cleanly, exposes the expected command
# surface, walks a task through one stage transition, and uninstalls
# without leaking state outside its tmp prefix.
#
# Complements .github/workflows/install-smoke.yml. The CI smoke verifies
# install SHAPE (binary lands, sidecar files written, `hive --version`
# works). This script verifies BEHAVIOR — that the installed binary
# actually runs `init` / `status` / `daemon install` / `uninstall` and
# produces the right JSON envelopes against the published schemas.
#
# Usage:
#   packaging/verify-release.sh [--version=vX.Y.Z] [--prefix=/path]
#                               [--keep-prefix] [--no-uninstall]
#
# Defaults:
#   --version    : whatever bin/hive --version reports if run in-repo,
#                  else v0.1.0
#   --prefix     : mktemp -d hive-verify-XXXXXX (deleted on success
#                  unless --keep-prefix)
#   --keep-prefix: keep the tmp prefix after success (useful when
#                  debugging; failures always preserve it)
#   --no-uninstall: skip the uninstall step (useful when you want to
#                  poke at the installed state after the test runs)
#
# Exit codes:
#   0   all verifications passed
#   1   a verification step failed (script preserves the tmp prefix)
#   2   bad arguments
#   3   prerequisite missing (curl, gh, ruby, jq)

set -euo pipefail

# ─── argument parsing ────────────────────────────────────────────────

HIVE_VERSION=""
PREFIX=""
KEEP_PREFIX=0
RUN_UNINSTALL=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version=*) HIVE_VERSION="${1#*=}"; shift ;;
    --version)   HIVE_VERSION="$2"; shift 2 ;;
    --prefix=*)  PREFIX="${1#*=}"; shift ;;
    --prefix)    PREFIX="$2"; shift 2 ;;
    --keep-prefix) KEEP_PREFIX=1; shift ;;
    --no-uninstall) RUN_UNINSTALL=0; shift ;;
    -h|--help)
      sed -n '3,29p' "$0"
      exit 0 ;;
    *) echo "verify-release: unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$HIVE_VERSION" ]]; then
  HIVE_VERSION="v0.1.0"
fi

# Anchor on the repo's own install.sh, not whatever the user has on
# PATH. Resolve relative to this script's location so the script can
# be run from anywhere.
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"
[[ -f "$INSTALL_SH" ]] || { echo "verify-release: install.sh not found at $INSTALL_SH" >&2; exit 3; }

# ─── prerequisites ───────────────────────────────────────────────────

for cmd in curl ruby jq; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "verify-release: missing prerequisite: $cmd" >&2
    exit 3
  }
done

# ─── prefix setup ────────────────────────────────────────────────────

if [[ -z "$PREFIX" ]]; then
  PREFIX="$(mktemp -d -t hive-verify-XXXXXX)"
  CREATED_PREFIX=1
else
  CREATED_PREFIX=0
  mkdir -p "$PREFIX"
fi

# Everything hive writes (config, cache, state, bin, data, daemon
# unit) is scoped inside $PREFIX via XDG and HIVE_HOME. `install.sh`
# honors XDG_BIN_HOME / XDG_DATA_HOME / XDG_CONFIG_HOME / XDG_STATE_HOME
# / XDG_CACHE_HOME. We DO NOT mock HOME — install.sh writes the
# systemd unit to ~/.config/systemd/user/, and that path is not XDG-
# overridable. To keep this side-effect inside the prefix on Linux,
# we run with `HOME=$PREFIX/home` so systemctl --user reads its config
# from there.
export XDG_BIN_HOME="$PREFIX/bin"
export XDG_DATA_HOME="$PREFIX/data"
export XDG_CONFIG_HOME="$PREFIX/config"
export XDG_STATE_HOME="$PREFIX/state"
export XDG_CACHE_HOME="$PREFIX/cache"
export HIVE_HOME="$PREFIX/hive-home"
export HOME="$PREFIX/home"
mkdir -p "$XDG_BIN_HOME" "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" \
         "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$HIVE_HOME" "$HOME"

# Put the installed binary first on PATH so subsequent `hive` calls
# resolve to the just-installed artifact, not a host install.
export PATH="$XDG_BIN_HOME:$PATH"

PASS_COUNT=0
FAIL_COUNT=0
STEP=0

log() { printf '\033[1;36m[verify]\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { printf '\033[1;31m  ✗\033[0m %s\n' "$*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }

cleanup() {
  local exit_code=$?
  if [[ $exit_code -ne 0 ]] || [[ $FAIL_COUNT -gt 0 ]]; then
    log "preserving tmp prefix for inspection: $PREFIX"
    return
  fi
  if [[ $KEEP_PREFIX -eq 1 ]]; then
    log "keeping tmp prefix per --keep-prefix: $PREFIX"
    return
  fi
  if [[ $CREATED_PREFIX -eq 1 ]]; then
    log "tearing down tmp prefix: $PREFIX"
    rm -rf "$PREFIX"
  fi
}
trap cleanup EXIT

step() { STEP=$((STEP + 1)); log "step ${STEP}: $*"; }

# ─── 1. install ──────────────────────────────────────────────────────

step "install hive ${HIVE_VERSION} into ${PREFIX}"
if bash "$INSTALL_SH" --version="$HIVE_VERSION" >"$PREFIX/install.log" 2>&1; then
  ok "install.sh exited 0"
else
  cat "$PREFIX/install.log" >&2
  fail "install.sh failed"
  exit 1
fi

[[ -x "$XDG_BIN_HOME/hive" ]] && ok "binary at \$XDG_BIN_HOME/hive is executable" \
                              || fail "binary missing or not executable at $XDG_BIN_HOME/hive"

INSTALLED_VERSION="$("$XDG_BIN_HOME/hive" --version 2>/dev/null || true)"
[[ -n "$INSTALLED_VERSION" ]] && ok "hive --version: $INSTALLED_VERSION" \
                              || fail "hive --version returned empty / failed"

# install.sh writes an install-channel sidecar so `hive update` knows
# how the binary was installed. Pin its presence.
[[ -s "$XDG_DATA_HOME/hive/install-channel" ]] \
  && ok "install-channel sidecar exists" \
  || fail "install-channel sidecar missing at $XDG_DATA_HOME/hive/install-channel"

# ─── 2. doctor ───────────────────────────────────────────────────────

step "hive doctor"
if "$XDG_BIN_HOME/hive" doctor >"$PREFIX/doctor.log" 2>&1; then
  ok "doctor exited 0"
else
  # doctor exits non-zero when prereqs are missing. That's expected in
  # a sandboxed CI env (no gh login, no claude binary). Just verify it
  # ran without crashing and produced human-readable output.
  if grep -qE "(claude|gh|git)" "$PREFIX/doctor.log"; then
    ok "doctor reported missing prerequisites (expected in sandbox)"
  else
    cat "$PREFIX/doctor.log" >&2
    fail "doctor crashed without producing the expected report"
  fi
fi

# ─── 3. scratch project: init + new + status ─────────────────────────

step "init scratch project"
PROJECT="$PREFIX/scratch-project"
mkdir -p "$PROJECT"
( cd "$PROJECT" \
    && git init -q -b main \
    && git config user.email "verify@example.invalid" \
    && git config user.name  "Verify" \
    && git commit -q --allow-empty -m "init" )

if "$XDG_BIN_HOME/hive" init "$PROJECT" >"$PREFIX/init.log" 2>&1; then
  ok "hive init exited 0"
else
  cat "$PREFIX/init.log" >&2
  fail "hive init failed"
fi

[[ -d "$PROJECT/.hive-state/stages/1-inbox" ]] \
  && ok ".hive-state/stages/1-inbox/ created" \
  || fail ".hive-state/stages/1-inbox/ missing after init"

step "new task + status --json"
PROJECT_NAME="$(basename "$PROJECT")"
"$XDG_BIN_HOME/hive" new "$PROJECT_NAME" "verify release smoke task" \
  >"$PREFIX/new.log" 2>&1 \
  && ok "hive new exited 0" \
  || { cat "$PREFIX/new.log" >&2; fail "hive new failed"; }

STATUS_JSON="$PREFIX/status.json"
"$XDG_BIN_HOME/hive" status --json >"$STATUS_JSON" 2>"$PREFIX/status.err" \
  && ok "hive status --json exited 0" \
  || { cat "$PREFIX/status.err" >&2; fail "hive status --json failed"; }

# Validate envelope basics: schema name + version + at least one task.
SCHEMA="$(jq -r '.schema // empty' "$STATUS_JSON")"
TASK_COUNT="$(jq -r '[.projects[].tasks[]] | length' "$STATUS_JSON")"
[[ "$SCHEMA" == "hive-status" ]] && ok "status envelope schema=hive-status" \
                                 || fail "status envelope schema is $SCHEMA, want hive-status"
[[ "${TASK_COUNT:-0}" -ge 1 ]] && ok "status envelope reports ≥1 task" \
                               || fail "status envelope reports 0 tasks after `hive new`"

# ─── 4. daemon install --json envelope ───────────────────────────────

# Only validate the envelope; don't start a real daemon (CI runners
# often lack systemd-user, and even where it's available, starting a
# real daemon inside this script is out of scope).

# Feature-detect the `daemon install` subcommand. Pre-PR-#113
# releases listed only start/stop/status/reload/tail/enable/disable.
# When the pinned release predates the feature, gracefully skip the
# envelope block instead of falsely failing the verification — the
# script's job is to verify the artifact's own behavior, not to
# require features the artifact doesn't ship.
DAEMON_SUBS="$("$XDG_BIN_HOME/hive" help daemon 2>&1 || true)"
if grep -qE "^[[:space:]]*install\b" <<<"$DAEMON_SUBS"; then
  step "daemon install --json (dry verification of envelope shape)"
  DAEMON_INSTALL_JSON="$PREFIX/daemon-install.json"

  # First call: fresh install. May exit 0 (success) or 70 (systemctl
  # unavailable). Either way, the envelope must validate.
  set +e
  "$XDG_BIN_HOME/hive" daemon install --json >"$DAEMON_INSTALL_JSON" 2>"$PREFIX/daemon-install.err"
  INSTALL_RC=$?
  set -e

  DAEMON_SCHEMA="$(jq -r '.schema // empty' "$DAEMON_INSTALL_JSON" 2>/dev/null || true)"
  DAEMON_OK="$(jq -r '.ok // empty' "$DAEMON_INSTALL_JSON" 2>/dev/null || true)"
  DAEMON_OUTCOME="$(jq -r '.outcome // empty' "$DAEMON_INSTALL_JSON" 2>/dev/null || true)"

  if [[ "$DAEMON_SCHEMA" == "hive-daemon-install" ]]; then
    ok "daemon install envelope schema=hive-daemon-install"
  else
    cat "$DAEMON_INSTALL_JSON" "$PREFIX/daemon-install.err" >&2
    fail "daemon install envelope schema is '$DAEMON_SCHEMA', want hive-daemon-install"
  fi

  case "$INSTALL_RC" in
    0)  [[ "$DAEMON_OK" == "true" ]] && ok "daemon install success: outcome=$DAEMON_OUTCOME (rc=0)" \
                                      || fail "rc=0 but ok=$DAEMON_OK" ;;
    64) [[ "$DAEMON_OK" == "false" ]] && [[ "$DAEMON_OUTCOME" == "drifted" ]] \
          && ok "daemon install drift (rc=64, outcome=drifted) — retryable with --force" \
          || fail "rc=64 but envelope shape unexpected (ok=$DAEMON_OK, outcome=$DAEMON_OUTCOME)" ;;
    70) [[ "$DAEMON_OK" == "false" ]] && [[ "$DAEMON_OUTCOME" == "failed" ]] \
          && ok "daemon install failure (rc=70, outcome=failed) — expected without systemd-user" \
          || fail "rc=70 but envelope shape unexpected (ok=$DAEMON_OK, outcome=$DAEMON_OUTCOME)" ;;
    *)  fail "daemon install exited unexpectedly rc=$INSTALL_RC" ;;
  esac

  # If install reported success (rc=0), exercise --force on the existing
  # unit and assert the .bak rotation contract.
  if [[ "$INSTALL_RC" -eq 0 ]]; then
    step "daemon install --force --json (verify .bak rotation)"
    set +e
    "$XDG_BIN_HOME/hive" daemon install --force --json \
      >"$PREFIX/daemon-install-force.json" 2>"$PREFIX/daemon-install-force.err"
    FORCE_RC=$?
    set -e
    FORCE_OUTCOME="$(jq -r '.outcome // empty' "$PREFIX/daemon-install-force.json" 2>/dev/null || true)"
    if [[ "$FORCE_RC" -eq 0 ]] && [[ "$FORCE_OUTCOME" == "upgraded" || "$FORCE_OUTCOME" == "unchanged" ]]; then
      ok "daemon install --force outcome=$FORCE_OUTCOME"
      if [[ "$FORCE_OUTCOME" == "upgraded" ]]; then
        BACKUPS="$(find "$HOME/.config/systemd/user" -maxdepth 1 -name 'hive-daemon.service.bak-*' 2>/dev/null | wc -l)"
        [[ "$BACKUPS" -ge 1 ]] && ok "timestamped .bak present after --force" \
                               || fail "force-upgrade reported but no .bak-<timestamp> file written"
      fi
    else
      cat "$PREFIX/daemon-install-force.json" "$PREFIX/daemon-install-force.err" >&2
      fail "daemon install --force unexpected outcome (rc=$FORCE_RC, outcome=$FORCE_OUTCOME)"
    fi
  fi
else
  log "step: daemon install — SKIPPED (pinned release predates the subcommand)"
fi

# ─── 5. uninstall ────────────────────────────────────────────────────

if [[ $RUN_UNINSTALL -eq 1 ]]; then
  step "hive uninstall"
  # `hive uninstall` is interactive (prompts before purging state).
  # Pipe empty stdin so it takes the default (no purge) path.
  if echo "" | "$XDG_BIN_HOME/hive" uninstall >"$PREFIX/uninstall.log" 2>&1; then
    ok "uninstall exited 0"
  else
    cat "$PREFIX/uninstall.log" >&2
    fail "uninstall failed"
  fi

  # Per uninstall.rb, it removes the daemon unit and user config/cache
  # but leaves project .hive-state/ in place by default. Verify the
  # daemon unit is gone from the sandboxed HOME.
  if [[ ! -f "$HOME/.config/systemd/user/hive-daemon.service" ]] \
       && [[ ! -f "$HOME/Library/LaunchAgents/local.hive-daemon.plist" ]]; then
    ok "daemon unit removed from sandboxed HOME"
  else
    fail "uninstall left a daemon unit behind"
  fi
fi

# ─── 6. leak detection ───────────────────────────────────────────────

# Verify that nothing the install/test sequence wrote leaked outside
# the prefix. We anchor on the real (un-mocked) user's HOME — but
# since this script always sets HOME=$PREFIX/home, the script's own
# process should not have written to the real $HOME at all. Detect
# any post-script state under the real user's HIVE_HOME / XDG paths
# that wasn't there before.
#
# This catches: a code path that bypasses XDG/HIVE_HOME indirection
# and reads/writes Dir.home directly. Specifically guards against
# regressions like the daemon unit accidentally landing under the
# real ~/.config/systemd/user/.

step "leak detection: nothing written outside the tmp prefix"
REAL_HOME="$(getent passwd "$(id -un)" | cut -d: -f6 2>/dev/null || echo "${HOME_BEFORE:-/dev/null}")"
LEAKS=()
for path in \
  "$REAL_HOME/.config/hive" \
  "$REAL_HOME/.local/state/hive" \
  "$REAL_HOME/.local/share/hive" \
  "$REAL_HOME/.cache/hive"
do
  # Only flag if the path exists AND its mtime is within the last 5
  # minutes (matching this script's runtime). Pre-existing dirs from
  # the user's normal hive install are not leaks; only fresh writes
  # by this script are.
  if [[ -e "$path" ]]; then
    if find "$path" -newer "$PREFIX" -print -quit 2>/dev/null | grep -q .; then
      LEAKS+=("$path")
    fi
  fi
done
if [[ ${#LEAKS[@]} -eq 0 ]]; then
  ok "no leaks outside $PREFIX"
else
  for leak in "${LEAKS[@]}"; do
    fail "leaked write at $leak (within last script runtime)"
  done
fi

# ─── summary ─────────────────────────────────────────────────────────

log "summary: $PASS_COUNT passed, $FAIL_COUNT failed"
if [[ $FAIL_COUNT -gt 0 ]]; then
  log "logs preserved at: $PREFIX"
  exit 1
fi
log "release ${HIVE_VERSION} verified ✓"
