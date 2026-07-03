#!/usr/bin/env bash
#
# verify-channel.sh — real-install verification for ONE install channel.
#
# Installs hive through the named channel on the current OS, then asserts the
# same behavioral contract regardless of channel: the binary reports the target
# version, the install-channel marker is correct, `doctor` runs, and a scratch
# project walks init → new → status. This is the shared verifier behind the
# pre-release gate, post-release verification, and the scheduled canary
# (.github/workflows/install-verify.yml).
#
# The `bash` channel delegates to packaging/verify-release.sh, which already
# owns the full XDG-sandboxed + leak-detection suite for install.sh. The `brew`
# and `aur` channels install system-wide, so this script resolves their binary
# and marker paths and runs the channel-agnostic behavioral core.
#
# Usage:
#   packaging/verify-channel.sh --channel bash|brew|aur --version vX.Y.Z
#                               [--report=text|json]
#
# Exit codes: 0 ok · 1 a check failed · 2 bad arguments · 3 prerequisite missing

set -euo pipefail

usage() {
  cat <<'HELP'
verify-channel.sh — real-install verification for one install channel.

USAGE:
  packaging/verify-channel.sh --channel bash|brew|aur --version vX.Y.Z
                              [--report=text|json]
HELP
}

CHANNEL=""
HIVE_VERSION=""
REPORT_FORMAT="text"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --channel=*) CHANNEL="${1#*=}"; shift ;;
    --channel)   CHANNEL="${2:-}"; shift 2 ;;
    --version=*) HIVE_VERSION="${1#*=}"; shift ;;
    --version)   HIVE_VERSION="${2:-}"; shift 2 ;;
    --report=*)  REPORT_FORMAT="${1#*=}"; shift ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "verify-channel: unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

case "$CHANNEL" in
  bash|brew|aur) ;;
  *) echo "verify-channel: --channel must be bash|brew|aur (got: '${CHANNEL}')" >&2; exit 2 ;;
esac
case "$REPORT_FORMAT" in text|json) ;; *) echo "verify-channel: --report must be text|json" >&2; exit 2 ;; esac
if [[ -z "$HIVE_VERSION" ]]; then
  echo "verify-channel: --version vX.Y.Z is required" >&2; exit 2
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Bare semver (no leading v) — the value `hive --version` prints.
EXPECTED_VERSION="${HIVE_VERSION#v}"

# ─── bash channel: delegate to the existing full-sandbox suite ────────
if [[ "$CHANNEL" == "bash" ]]; then
  exec bash "$REPO_ROOT/packaging/verify-release.sh" \
    --version="$HIVE_VERSION" --report="$REPORT_FORMAT"
fi

# ─── brew / aur: channel-agnostic behavioral core ─────────────────────

PASS=0
FAIL=0
ok()   { printf '  ok   %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }
log()  { printf '[verify-channel:%s] %s\n' "$CHANNEL" "$*"; }

git_clone_retry() {
  local url="$1"
  local dest="$2"
  local attempt rc
  for attempt in 1 2 3; do
    rm -rf "$dest"
    if git clone --depth 1 "$url" "$dest"; then
      return 0
    fi
    rc=$?
    if [[ "$attempt" -eq 3 ]]; then
      return "$rc"
    fi
    log "git clone failed (attempt ${attempt}/3, rc=${rc}); retrying"
    sleep $((attempt * 2))
  done
}

# Resolve the channel's install command, expected binary, and marker path.
HIVE_BIN=""
MARKER_PATH=""

install_brew() {
  command -v brew >/dev/null 2>&1 || { echo "brew not found" >&2; exit 3; }
  # The formula depends_on "ruby"; the gem needs >= 3.4. Fail early with a
  # clear message if Homebrew's ruby is older, rather than a murky gem error.
  local brew_ruby
  brew_ruby="$(brew list --versions ruby 2>/dev/null | awk '{print $2}' | head -n1 || true)"
  if [[ -n "$brew_ruby" ]]; then
    if [[ "$(printf '%s\n3.4.0\n' "$brew_ruby" | sort -V | head -n1)" != "3.4.0" ]]; then
      log "note: Homebrew ruby ${brew_ruby} is below the gemspec floor 3.4.0 (install may fail)"
    fi
  fi
  brew install ivankuznetsov/hive/hive
  local prefix
  prefix="$(brew --prefix)"
  HIVE_BIN="${prefix}/bin/hive"
  MARKER_PATH="${prefix}/share/hive/install-channel"
}

install_aur() {
  # Real user path: an AUR helper if present, else build the published package.
  if command -v yay >/dev/null 2>&1; then
    yay -S --noconfirm --needed hive-bin
  elif command -v paru >/dev/null 2>&1; then
    paru -S --noconfirm --needed hive-bin
  else
    # No helper: clone the published AUR package and build it. makepkg refuses
    # root, so the caller must run this script as a non-root user with sudo.
    command -v makepkg >/dev/null 2>&1 || { echo "neither yay/paru nor makepkg found" >&2; exit 3; }
    local build
    build="$(mktemp -d)"
    git_clone_retry "https://aur.archlinux.org/hive-bin.git" "$build/hive-bin"
    ( cd "$build/hive-bin" && makepkg -si --noconfirm --needed )
  fi
  HIVE_BIN="/usr/bin/hive"
  MARKER_PATH="/usr/share/hive/install-channel"
}

log "installing hive ${HIVE_VERSION} via ${CHANNEL}"
case "$CHANNEL" in
  brew) install_brew ;;
  aur)  install_aur ;;
esac

# 1. binary present + version
if [[ -x "$HIVE_BIN" ]]; then ok "binary present at ${HIVE_BIN}"; else fail "no executable at ${HIVE_BIN}"; fi
got_version="$("$HIVE_BIN" --version 2>/dev/null | head -n1 || true)"
if [[ "$got_version" == "$EXPECTED_VERSION" ]]; then
  ok "hive --version == ${EXPECTED_VERSION}"
else
  fail "hive --version is '${got_version}', want '${EXPECTED_VERSION}'"
fi

# 2. install-channel marker
marker_content="$(cat "$MARKER_PATH" 2>/dev/null | tr -d '[:space:]' || true)"
if [[ "$marker_content" == "$CHANNEL" ]]; then
  ok "install-channel marker == ${CHANNEL}"
else
  fail "marker at ${MARKER_PATH} is '${marker_content}', want '${CHANNEL}'"
fi

# 3. hv fallback (Apache Hive PATH-collision shim ships with every channel)
hv_bin="$(dirname "$HIVE_BIN")/hv"
if [[ -e "$hv_bin" ]] && "$hv_bin" --version >/dev/null 2>&1; then
  ok "hv fallback works"
else
  fail "hv fallback missing or broken at ${hv_bin}"
fi

# 4. doctor runs (tolerate non-zero in a CI sandbox lacking LLM CLIs/skills;
#    a crash lacks the signature report header).
doctor_out="$("$HIVE_BIN" doctor 2>&1 || true)"
if printf '%s\n' "$doctor_out" | grep -qE '^stage[[:space:]]+agent[[:space:]]+skill[[:space:]]+status' \
   || "$HIVE_BIN" doctor >/dev/null 2>&1; then
  ok "doctor produced its report"
else
  fail "doctor crashed (no signature header)"
fi

# 5. scratch project: init → new → status --json
project="$(mktemp -d)/scratch"
mkdir -p "$project"
( cd "$project" \
    && git init -q -b main \
    && git config user.email "verify@example.invalid" \
    && git config user.name "Verify" \
    && git commit -q --allow-empty -m "init" )
if "$HIVE_BIN" init "$project" >/dev/null 2>&1; then ok "hive init exited 0"; else fail "hive init failed"; fi
if [[ -d "$project/.hive-state/stages/1-inbox" ]]; then ok ".hive-state/stages/1-inbox created"; else fail "init did not scaffold .hive-state"; fi
if "$HIVE_BIN" new "$(basename "$project")" "channel verify smoke" >/dev/null 2>&1; then ok "hive new exited 0"; else fail "hive new failed"; fi
status_json="$("$HIVE_BIN" status --json 2>/dev/null || true)"
if printf '%s' "$status_json" | grep -q '"schema":"hive-status"'; then
  ok "status --json emits hive-status envelope"
else
  fail "status --json did not emit a hive-status envelope"
fi

log "summary: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]] || exit 1
log "channel ${CHANNEL} verified for ${HIVE_VERSION}"
