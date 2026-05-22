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
#   --version    : v0.1.0 (override to verify a different release)
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
#   3   prerequisite missing (curl, ruby, jq, git)

set -euo pipefail

# ─── argument parsing ────────────────────────────────────────────────

HIVE_VERSION=""
PREFIX=""
KEEP_PREFIX=0
RUN_UNINSTALL=1

# Argument dialect matches install.sh: --flag=value only. Drops the
# space-separated form so two release-ceremony scripts share one
# parser convention.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version=*) HIVE_VERSION="${1#*=}"; shift ;;
    --prefix=*)  PREFIX="${1#*=}"; shift ;;
    --keep-prefix) KEEP_PREFIX=1; shift ;;
    --no-uninstall) RUN_UNINSTALL=0; shift ;;
    -h|--help)
      sed -n '3,29p' "$0"
      exit 0 ;;
    *) echo "verify-release: unknown argument: $1 (try --help)" >&2; exit 2 ;;
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

for cmd in curl ruby jq git; do
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

# Capture the real user's HOME BEFORE overwriting it — the leak
# detector at the end of the script needs to scan the real home,
# not the sandboxed one. Done this way (capture into HOME_BEFORE)
# rather than via getent so macOS works too (getent doesn't exist).
HOME_BEFORE="${HOME:-}"
if [[ -z "$HOME_BEFORE" ]]; then
  echo "verify-release: \$HOME is unset; leak detection cannot run" >&2
  exit 3
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

# Sentinel file for leak detection: anchor `find -newer` on a file
# whose mtime never moves, not on $PREFIX (whose mtime updates every
# time a child file is added — which would mask early leaks because
# the reference timestamp drifts toward end-of-script).
START_MARKER="$PREFIX/.start-marker"
: > "$START_MARKER"

# Put the installed binary first on PATH so subsequent `hive` calls
# resolve to the just-installed artifact, not a host install.
export PATH="$XDG_BIN_HOME:$PATH"

PASS_COUNT=0
FAIL_COUNT=0
STEP=0

# ANSI colors only when stdout is a TTY and NO_COLOR is unset (per
# no-color.org). CI typically captures stdout non-interactively;
# emitting raw escape codes there pollutes log parsers.
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
  C_INFO=$'\033[1;36m'; C_OK=$'\033[1;32m'; C_FAIL=$'\033[1;31m'; C_RESET=$'\033[0m'
else
  C_INFO=""; C_OK=""; C_FAIL=""; C_RESET=""
fi

log() { printf '%s[verify]%s %s\n' "$C_INFO" "$C_RESET" "$*"; }
ok()  { printf '%s  ✓%s %s\n' "$C_OK" "$C_RESET" "$*"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { printf '%s  ✗%s %s\n' "$C_FAIL" "$C_RESET" "$*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }

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
# `timeout 300` bounds the install at 5 minutes. install.sh downloads
# release tarballs from GitHub via curl/gh; if the CDN stalls (TCP
# connect succeeds but bytes stop flowing) curl waits on its unbounded
# default. Without the timeout, verify-release.sh hangs until GHA's
# 6h job-level cap fires. timeout returns 124 on expiry.
set +e
timeout 300 bash "$INSTALL_SH" --version="$HIVE_VERSION" >"$PREFIX/install.log" 2>&1
INSTALL_RC=$?
set -e
case "$INSTALL_RC" in
  0)   ok "install.sh exited 0" ;;
  124) cat "$PREFIX/install.log" >&2 2>/dev/null || true
       fail "install.sh timed out after 300s (network stall or CDN unreachable)"
       exit 1 ;;
  *)   cat "$PREFIX/install.log" >&2 2>/dev/null || true
       fail "install.sh failed (rc=$INSTALL_RC)"
       exit 1 ;;
esac

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
set +e
"$XDG_BIN_HOME/hive" doctor >"$PREFIX/doctor.log" 2>&1
DOCTOR_RC=$?
set -e
# doctor signals "ran and produced a report" by emitting its
# signature header (a fixed-width status table starting with "stage"
# / "agent" / "skill" / "status"). A real crash (NoMethodError,
# LoadError, syntax error) lacks that header. Discriminating on
# output shape rather than exit code lets the script tolerate
# doctor's varied non-zero codes (1, 65 EX_DATAERR, 70 SOFTWARE)
# while still catching genuine crashes.
if [[ "$DOCTOR_RC" -eq 0 ]]; then
  ok "doctor exited 0 (all prereqs present)"
elif grep -qE '^stage[[:space:]]+agent[[:space:]]+skill[[:space:]]+status' "$PREFIX/doctor.log"; then
  ok "doctor reported issues (rc=$DOCTOR_RC, expected in CI sandbox without LLM CLIs/skills)"
else
  cat "$PREFIX/doctor.log" >&2 2>/dev/null || true
  fail "doctor exited unexpectedly (rc=$DOCTOR_RC) — output lacks the signature report header, likely a crash"
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
  || { cat "$PREFIX/status.err" >&2 2>/dev/null || true; fail "hive status --json failed"; }

# Validate envelope shape: schema name, then probe the new task's
# stage/marker/action so a regression that creates the row in the
# wrong stage (or with the wrong marker / wrong action key) fails
# loudly. jq calls are made defensive with `|| true` so a malformed
# envelope produces a clean fail line instead of aborting the script
# mid-step under set -e.
SCHEMA="$(jq -r '.schema // empty' "$STATUS_JSON" 2>/dev/null || true)"
TASK_COUNT="$(jq -r '[.projects[].tasks[]] | length' "$STATUS_JSON" 2>/dev/null || echo 0)"
NEW_TASK_STAGE="$(jq -r '[.projects[].tasks[]][0].stage // empty' "$STATUS_JSON" 2>/dev/null || true)"
NEW_TASK_MARKER="$(jq -r '[.projects[].tasks[]][0].marker // empty' "$STATUS_JSON" 2>/dev/null || true)"
NEW_TASK_ACTION="$(jq -r '[.projects[].tasks[]][0].action // empty' "$STATUS_JSON" 2>/dev/null || true)"

[[ "$SCHEMA" == "hive-status" ]] && ok "status envelope schema=hive-status" \
                                 || fail "status envelope schema is '$SCHEMA', want hive-status"
[[ "${TASK_COUNT:-0}" -ge 1 ]] && ok "status envelope reports >=1 task" \
                               || fail "status envelope reports 0 tasks after 'hive new'"
[[ "$NEW_TASK_STAGE" == "1-inbox" ]] && ok "new task at stage=1-inbox" \
                                     || fail "new task at stage='$NEW_TASK_STAGE', want 1-inbox"
[[ "$NEW_TASK_MARKER" == "waiting" ]] && ok "new task marker=waiting" \
                                      || fail "new task marker='$NEW_TASK_MARKER', want waiting"
[[ "$NEW_TASK_ACTION" == "ready_to_brainstorm" ]] && ok "new task action=ready_to_brainstorm" \
                                                  || fail "new task action='$NEW_TASK_ACTION', want ready_to_brainstorm"

# ─── 4. daemon install --json envelope ───────────────────────────────

# Only validate the envelope; don't start a real daemon (CI runners
# often lack systemd-user, and even where it's available, starting a
# real daemon inside this script is out of scope).

# Feature-detect the `daemon install` subcommand by listing the
# binary's VALID_SUBCOMMANDS via the unknown-subcommand error path.
# Calling `hive daemon <impossible-token>` triggers Thor's reflection
# and prints "expected: start, stop, status, reload, tail, ..." which
# we grep for the literal token "install". This is more robust than:
#   - `hive daemon install --help` (Thor falls back to parent help
#     with rc=0 when the subcommand doesn't exist, masking the gap)
#   - `hive help daemon` (Thor reflows long_desc into wrapped prose
#     where "install" can appear mid-line)
# Pre-PR-#113 releases list start/stop/status/reload/tail/enable/disable
# only. Releases that ship the subcommand list "install" in the
# "expected:" enumeration. Gracefully skip the envelope block when
# the artifact doesn't ship the feature — the script's job is to
# verify the artifact's own behavior, not to require features it
# doesn't ship.
DAEMON_PROBE_ERR="$PREFIX/daemon-probe.err"
set +e
"$XDG_BIN_HOME/hive" daemon __verify_release_probe_nonexistent_subcommand__ \
  >/dev/null 2>"$DAEMON_PROBE_ERR"
set -e
DAEMON_INSTALL_AVAILABLE=0
if grep -qE 'expected:[^)]*\binstall\b' "$DAEMON_PROBE_ERR" 2>/dev/null; then
  DAEMON_INSTALL_AVAILABLE=1
fi
if [[ "$DAEMON_INSTALL_AVAILABLE" -eq 1 ]]; then
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
# Anchor on HOME_BEFORE (captured at script start, before HOME was
# overwritten). Drops the getent dependency that didn't work on
# macOS. The scan list includes the systemd unit + macOS plist
# paths explicitly — those are the regression class the comment
# above calls out, and they live OUTSIDE the XDG dirs.
LEAKS=()
for path in \
  "$HOME_BEFORE/.config/hive" \
  "$HOME_BEFORE/.local/state/hive" \
  "$HOME_BEFORE/.local/share/hive" \
  "$HOME_BEFORE/.cache/hive" \
  "$HOME_BEFORE/.config/systemd/user/hive-daemon.service" \
  "$HOME_BEFORE/Library/LaunchAgents/local.hive-daemon.plist"
do
  # Flag if the path exists AND has any descendant newer than the
  # sentinel file ($START_MARKER) created at script start. Using a
  # sentinel anchor avoids the trap where `find -newer "$PREFIX"`
  # silently fails to flag early leaks because $PREFIX's own mtime
  # advances as the script writes child files into it.
  if [[ -e "$path" ]]; then
    if find "$path" -newer "$START_MARKER" -print -quit 2>/dev/null | grep -q .; then
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
