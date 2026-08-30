#!/usr/bin/env bash
set -euo pipefail

REPO_OWNER="${HIVE_REPO_OWNER:-ivankuznetsov}"
REPO_NAME="${HIVE_REPO_NAME:-hive}"
DRY_RUN=0
VERSION="${HIVE_VERSION:-}"
PREFIX="${HIVE_PREFIX:-}"
INSTALL_QMD="${HIVE_INSTALL_QMD:-1}"
DEFAULT_QMD_NPM_PACKAGE="@tobilu/qmd@2.5.3"
DEFAULT_QMD_NPM_INTEGRITY="sha512-wUKc4pSPDbgs7mV7JYE8/Qj1pNXXatJFV8byTT/T3yLaoAXheFtWu0BgSWwoWGhRkMmxl5Qyitt66NHgbMyeBA=="
QMD_NPM_PACKAGE="${HIVE_QMD_NPM_PACKAGE:-${DEFAULT_QMD_NPM_PACKAGE}}"
QMD_NPM_INTEGRITY="${DEFAULT_QMD_NPM_INTEGRITY}"
QMD_TIMEOUT_SECONDS="${HIVE_QMD_TIMEOUT_SECONDS:-600}"

usage() {
  cat <<USAGE
usage: install.sh [--dry-run] [--prefix=<dir>] [--version=<tag>]

Installs hive as a rubygem (\`hive-cli\`) from GitHub Releases. The .gem
is signed with cosign keyless attestation against this repo's release
workflow; verification always fails closed when cosign is unavailable.

After install the \`hive\` and \`hv\` executables are symlinked into
\${XDG_BIN_HOME:-~/.local/bin}. The installer also runs \`hive daemon install\`
to write and enable the per-user daemon autostart unit when the host supports
it. The gem and its runtime dependencies (bubbletea, lipgloss, thor,
telegram-bot-ruby) live under \${HIVE_PREFIX:-~/.local/share}/hive/gems so an
uninstall is a clean \`rm -rf\` plus symlink removal.

Requires Ruby 3.4 already on PATH; the installer reports its own
prereqs (\`curl\`, \`jq\`, \`cosign\`, checksum tool) on first run. When npm is
available, the installer also installs Hive's qmd wiki indexer into the
Hive data directory and links it beside the \`hive\` executable. Set
HIVE_INSTALL_QMD=0 to skip that step.

QMD env knobs:
  HIVE_QMD_NPM_PACKAGE  QMD package spec. Must match the release-owned
                        dependency lock: \`${DEFAULT_QMD_NPM_PACKAGE}\`.
  HIVE_QMD_NPM_INTEGRITY
                        Deprecated compatibility input. When set, it must
                        equal the release-owned integrity exactly.
  HIVE_QMD_TIMEOUT_SECONDS
                        Timeout for each optional npm/QMD/Node subprocess;
                        defaults to ${QMD_TIMEOUT_SECONDS} seconds.
  HIVE_QMD_BIN          Runtime override read by generated wiki scripts
                        and \`hive doctor\`; points at an executable
                        \`qmd\` when PATH or the managed install path is
                        not enough.
USAGE
}

log() {
  printf '%s\n' "$*"
}

warn() {
  printf 'hive install: %s\n' "$*" >&2
}

die() {
  warn "$*"
  exit 1
}

# Validate caller-controlled env vars so we never interpolate
# attacker-shaped values into curl URLs.
validate_inputs() {
  if [[ -n "$VERSION" ]] && ! [[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]]; then
    die "invalid HIVE_VERSION '${VERSION}'; expected vMAJOR.MINOR.PATCH[-pre]"
  fi
  if [[ -n "$REPO_OWNER" ]] && ! [[ "$REPO_OWNER" =~ ^[A-Za-z0-9._-]+$ ]]; then
    die "invalid HIVE_REPO_OWNER '${REPO_OWNER}'"
  fi
  if [[ -n "$REPO_NAME" ]] && ! [[ "$REPO_NAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
    die "invalid HIVE_REPO_NAME '${REPO_NAME}'"
  fi
  case "$INSTALL_QMD" in
    0|false|False|FALSE|no|No|NO) return 0 ;;
  esac
  if [[ "$QMD_NPM_PACKAGE" != "$DEFAULT_QMD_NPM_PACKAGE" ]]; then
    die "unsupported HIVE_QMD_NPM_PACKAGE '${QMD_NPM_PACKAGE}'; release dependency lock requires ${DEFAULT_QMD_NPM_PACKAGE}"
  fi
  if [[ -n "${HIVE_QMD_NPM_INTEGRITY:-}" &&
        "$HIVE_QMD_NPM_INTEGRITY" != "$DEFAULT_QMD_NPM_INTEGRITY" ]]; then
    die "unsupported HIVE_QMD_NPM_INTEGRITY; release dependency lock requires the published ${DEFAULT_QMD_NPM_PACKAGE} integrity"
  fi
  if ! [[ "$QMD_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
    die "invalid HIVE_QMD_TIMEOUT_SECONDS '${QMD_TIMEOUT_SECONDS}'; expected positive integer seconds"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      ;;
    --prefix=*)
      PREFIX="${1#--prefix=}"
      ;;
    --version=*)
      VERSION="${1#--version=}"
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
  shift
done

validate_inputs

# musl Linux and NixOS rejected at this layer because precompiled
# bubbletea / lipgloss gems for musl are sparser than for glibc and
# NixOS's read-only /nix store interacts badly with `gem install`.
# Both routes need separate operational guidance; see wiki/operating.md.
detect_platform() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"

  case "$os" in
    Darwin)
      [[ "$arch" == "arm64" ]] || die "unsupported platform: macOS ${arch}; tier-1 target is darwin-arm64"
      printf 'darwin-arm64\n'
      ;;
    Linux)
      if compgen -G "/lib/ld-musl-*" >/dev/null 2>&1 || compgen -G "/lib64/ld-musl-*" >/dev/null 2>&1; then
        die "unsupported platform: musl Linux is tier-3; see wiki/operating.md"
      fi
      if [[ -f /etc/os-release ]] && grep -qi '^ID=nixos' /etc/os-release; then
        die "unsupported platform: NixOS is tier-3; see wiki/operating.md"
      fi
      case "$arch" in
        x86_64|amd64) printf 'linux-x86_64-gnu\n' ;;
        aarch64|arm64) printf 'linux-aarch64-gnu\n' ;;
        *) die "unsupported Linux architecture: ${arch}" ;;
      esac
      ;;
    *)
      die "unsupported platform: ${os}; tier-1 targets are macOS arm64 and glibc Linux"
      ;;
  esac
}

latest_version() {
  local api body tag http_code response rc
  api="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest"
  # `set -e` short-circuits command substitutions on non-zero exit, so
  # capture under `|| true` and recover the real exit via PIPESTATUS.
  response="$(curl -sS -L -w '\n%{http_code}' "$api" 2>/dev/null)" || rc=$?
  rc="${rc:-0}"
  http_code="${response##*$'\n'}"
  body="${response%$'\n'*}"
  if [[ "$rc" -ne 0 || "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    case "$http_code" in
      403) die "could not fetch latest release (HTTP 403 — likely GitHub API rate limit); set HIVE_VERSION=vX.Y.Z to skip the API call" ;;
      404) die "could not fetch latest release (HTTP 404 — no published release for ${REPO_OWNER}/${REPO_NAME}); set HIVE_VERSION=vX.Y.Z" ;;
      000) die "could not fetch latest release (curl exit ${rc}; no HTTP response — DNS / network unreachable); set HIVE_VERSION=vX.Y.Z to skip the API call" ;;
      *) die "could not fetch latest release (curl exit ${rc}, HTTP ${http_code}); set HIVE_VERSION=vX.Y.Z to skip the API call" ;;
    esac
  fi
  tag="$(printf '%s\n' "$body" | jq -r '.tag_name // empty')"
  [[ -n "$tag" && "$tag" != "null" ]] || die "could not parse tag_name from latest release; set HIVE_VERSION=vX.Y.Z"
  printf '%s\n' "$tag"
}

# Download a URL with status-branching semantics so the caller can
# distinguish 403 (rate limit / forbidden), 404 (artifact missing),
# DNS / network errors (HTTP 000), and other failures. Body goes to
# `$out_path`; the message uses `$what` to identify the resource in
# the user-visible error.
download_with_status() {
  local url="$1" out_path="$2" what="${3:-resource}" http_code rc
  http_code="$(curl -sS -L -o "$out_path" -w '%{http_code}' "$url" 2>/dev/null)" || rc=$?
  rc="${rc:-0}"
  if [[ "$rc" -ne 0 || "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    case "$http_code" in
      403) die "could not fetch ${what} from ${url} (HTTP 403 — likely rate limit / forbidden); retry later or set HIVE_VERSION=vX.Y.Z" ;;
      404) die "could not fetch ${what} from ${url} (HTTP 404 — release artifact missing); confirm HIVE_VERSION points at a published release" ;;
      000) die "could not fetch ${what} from ${url} (curl exit ${rc}; no HTTP response — DNS / network unreachable)" ;;
      *) die "could not fetch ${what} from ${url} (curl exit ${rc}, HTTP ${http_code})" ;;
    esac
  fi
}

sha256_cmd() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf 'sha256sum\n'
  elif command -v shasum >/dev/null 2>&1; then
    printf 'shasum -a 256\n'
  else
    die "missing checksum tool: install sha256sum or shasum"
  fi
}

install_hint() {
  local dep="$1"
  case "$(uname -s)" in
    Darwin) printf 'brew install %s' "$dep" ;;
    Linux)
      if [[ -f /etc/arch-release ]]; then
        printf 'sudo pacman -S %s' "$dep"
      else
        printf 'sudo apt install %s' "$dep"
      fi
      ;;
    *) printf 'install %s with your OS package manager' "$dep" ;;
  esac
}

# Hard checks for tools the installer itself needs. Run BEFORE any
# download attempt so we fail with an actionable message instead of
# crashing mid-curl / mid-gem-install with a confusing trace.
installer_preflight() {
  local dep missing=0
  for dep in curl jq; do
    if ! command -v "$dep" >/dev/null 2>&1; then
      warn "missing installer prerequisite '${dep}' ($(install_hint "$dep"))"
      missing=1
    fi
  done
  if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
    warn "missing installer prerequisite 'sha256sum' or 'shasum' ($(install_hint "coreutils"))"
    missing=1
  fi
  if [[ "$missing" -ne 0 ]]; then
    die "install aborted: required installer prerequisites missing — fix the warnings above and re-run"
  fi
}

# Ruby 3.4+ is required by hive.gemspec; gem install will refuse
# otherwise. Skipped under --dry-run because dry-run is a preview /
# argument-shape lint and CI runners often pin older system Rubies.
ruby_preflight() {
  local dep missing=0
  for dep in ruby gem; do
    if ! command -v "$dep" >/dev/null 2>&1; then
      warn "missing installer prerequisite '${dep}' (install Ruby 3.4 with rbenv / mise / asdf, or your OS package manager)"
      missing=1
    fi
  done
  if [[ "$missing" -ne 0 ]]; then
    die "install aborted: Ruby 3.4 is required — fix the warnings above and re-run"
  fi
  if ! ruby -e 'exit(RUBY_VERSION.to_f >= 3.4)' 2>/dev/null; then
    die "Ruby 3.4+ required; found $(ruby -e 'print RUBY_VERSION' 2>/dev/null || echo unknown)"
  fi
}

# Warn-only check for runtime tools the installed CLI uses at run time
# (`hive run`, `hive doctor`, agent CLIs). Per plan U2 these are never
# auto-installed; missing them does NOT fail the installer — the gem
# is already on disk and `hive --version`, `hive doctor`, and
# `hive update` keep working.
runtime_preflight() {
  local dep
  for dep in git bash claude gh; do
    if ! command -v "$dep" >/dev/null 2>&1; then
      warn "missing runtime dependency '${dep}' — install with: $(install_hint "$dep")"
    fi
  done
}

qmd_install_enabled() {
  case "$INSTALL_QMD" in
    0|false|False|FALSE|no|No|NO) return 1 ;;
    *) return 0 ;;
  esac
}

qmd_repair_hint() {
  printf 'rerun hive update after fixing npm/Node.js; Hive keeps the previous managed qmd until a verified replacement is ready'
}

# Resolve an existing path without GNU-only `readlink -f`. Ruby is already a
# hard prerequisite on real installs, and File.realpath behaves consistently
# on macOS and Linux. If the target disappeared between the existence check
# and resolution, fall back symmetrically to the absolute lexical path.
canonical_existing_path() {
  ruby -e 'begin; print File.realpath(ARGV.fetch(0)); rescue SystemCallError; print File.expand_path(ARGV.fetch(0)); end' "$1"
}

run_with_timeout() {
  local seconds="$1"
  shift
  ruby -rtimeout -e '
    seconds = Integer(ARGV.shift, 10)
    pid = Process.spawn(*ARGV, pgroup: true)
    status = nil
    begin
      Timeout.timeout(seconds) { _pid, status = Process.wait2(pid) }
    rescue Timeout::Error
      begin
        Process.kill("TERM", -pid)
      rescue Errno::ESRCH
      end
      begin
        Timeout.timeout(2) { _pid, status = Process.wait2(pid) }
      rescue Timeout::Error
        begin
          Process.kill("KILL", -pid)
        rescue Errno::ESRCH
        end
        begin
          _pid, status = Process.wait2(pid)
        rescue Errno::ECHILD
        end
      rescue Errno::ECHILD
      end
      exit 124
    end
    exit(status&.exitstatus || 1)
  ' "$seconds" "$@"
}

qmd_command_failed() {
  local operation="$1" rc="$2"
  if [[ "$rc" -eq 124 ]]; then
    warn "qmd ${operation} timed out after ${QMD_TIMEOUT_SECONDS}s; $(qmd_repair_hint)"
  else
    warn "qmd ${operation} failed (exit ${rc}); $(qmd_repair_hint)"
  fi
}

# Install the qmd CLI used by Hive-managed llm-wiki refresh scripts into
# Hive's own data prefix. This keeps the native better-sqlite3 build out
# of the user's global npm prefix while still making `qmd` available from
# the same bin directory as `hive`.
install_qmd() {
  local qmd_home qmd_bin qmd_link qmd_stage qmd_stage_bin qmd_package_json
  local qmd_download_dir qmd_pack_json qmd_tarball qmd_tarball_integrity qmd_backup
  local qmd_lock_root qmd_install_root qmd_node_header_root qmd_node_gyp qmd_better_sqlite
  local existing_qmd_link active_qmd active_qmd_canon managed_qmd_canon qmd_version rc
  local qmd_had_original=0
  qmd_home="${data_home}/qmd"
  qmd_bin="${qmd_home}/bin/qmd"
  qmd_link="${bin_home}/qmd"

  if ! qmd_install_enabled; then
    log "qmd: skipped (HIVE_INSTALL_QMD=${INSTALL_QMD})"
    return 0
  fi

  if ! command -v npm >/dev/null 2>&1; then
    warn "missing wiki dependency 'npm'; qmd was not installed — install Node.js/npm and rerun hive update"
    return 0
  fi

  qmd_lock_root="${gem_home}/gems/hive-cli-${gem_version}/lib/hive/assets/qmd"
  if [[ -f "${qmd_lock_root}/package.json" && -f "${qmd_lock_root}/package-lock.json" ]]; then
    :
  else
    warn "release-owned qmd dependency lock is unavailable; qmd was not installed"
    return 0
  fi

  log "qmd: downloading and verifying ${QMD_NPM_PACKAGE}"
  mkdir -p "$data_home"
  qmd_download_dir="$(mktemp -d "${tmpdir}/qmd-package.XXXXXX")"
  if qmd_pack_json="$(run_with_timeout "$QMD_TIMEOUT_SECONDS" \
    npm pack "$QMD_NPM_PACKAGE" --json --pack-destination "$qmd_download_dir")"; then
    :
  else
    rc=$?
    qmd_command_failed "package download" "$rc"
    return 0
  fi

  if qmd_tarball="$(printf '%s' "$qmd_pack_json" | ruby -rjson -e '
    entry = JSON.parse(STDIN.read).fetch(0)
    filename = entry.fetch("filename")
    abort "unsafe npm pack filename" unless File.basename(filename) == filename && filename.end_with?(".tgz")
    print File.join(ARGV.fetch(0), filename)
  ' "$qmd_download_dir")" && [[ -f "$qmd_tarball" && ! -L "$qmd_tarball" ]]; then
    :
  else
    warn "qmd package download returned no safe tarball for ${QMD_NPM_PACKAGE}; $(qmd_repair_hint)"
    return 0
  fi

  qmd_tarball_integrity="$(ruby -rdigest -rbase64 -e '
    digest = Digest::SHA512.file(ARGV.fetch(0)).digest
    print "sha512-", Base64.strict_encode64(digest)
  ' "$qmd_tarball")"
  if [[ "$qmd_tarball_integrity" != "$QMD_NPM_INTEGRITY" ]]; then
    warn "qmd package integrity mismatch for ${QMD_NPM_PACKAGE}; refusing npm install"
    return 0
  fi

  qmd_stage="$(mktemp -d "${data_home}/.qmd-stage.XXXXXX")"
  qmd_rollback_stage="$qmd_stage"
  qmd_stage_bin="${qmd_stage}/bin/qmd"
  qmd_install_root="${qmd_stage}/lib"
  mkdir -p "$qmd_install_root" "${qmd_stage}/bin"
  cp "${qmd_lock_root}/package.json" "${qmd_install_root}/package.json"
  cp "${qmd_lock_root}/package-lock.json" "${qmd_install_root}/package-lock.json"
  cp "$qmd_tarball" "${qmd_install_root}/qmd.tgz"
  log "qmd: installing verified package and locked dependency closure into staging"
  if run_with_timeout "$QMD_TIMEOUT_SECONDS" \
    npm ci --prefix "$qmd_install_root" --ignore-scripts --no-audit --no-fund; then
    :
  else
    rc=$?
    qmd_command_failed "install" "$rc"
    rm -rf "$qmd_stage"
    return 0
  fi
  rm -f "${qmd_install_root}/qmd.tgz"
  ln -s "../lib/node_modules/.bin/qmd" "$qmd_stage_bin"

  # Lifecycle scripts are disabled above so dependency packages cannot fetch
  # mutable prebuilds outside package-lock integrity. Build better-sqlite3
  # directly from its verified package source with the locked node-gyp and the
  # local Node installation's headers. Supplying --nodedir and offline mode
  # prevents node-gyp from downloading a second, unpinned input.
  if qmd_node_header_root="$(run_with_timeout "$QMD_TIMEOUT_SECONDS" node -e '
    const fs = require("node:fs");
    const path = require("node:path");
    const prefix = path.dirname(path.dirname(process.execPath));
    const candidates = [prefix, path.dirname(prefix), "/usr"];
    const root = candidates.find(candidate => fs.existsSync(path.join(candidate, "include", "node", "node.h")));
    if (!root) process.exit(1);
    process.stdout.write(root);
  ')"; then
    :
  else
    rc=$?
    qmd_command_failed "local Node header discovery" "$rc"
    rm -rf "$qmd_stage"
    return 0
  fi
  qmd_node_gyp="${qmd_install_root}/node_modules/node-gyp/bin/node-gyp.js"
  qmd_better_sqlite="${qmd_install_root}/node_modules/better-sqlite3"
  if [[ ! -f "$qmd_node_gyp" || ! -f "${qmd_better_sqlite}/binding.gyp" ]]; then
    warn "qmd locked native-build inputs are unavailable; $(qmd_repair_hint)"
    rm -rf "$qmd_stage"
    return 0
  fi
  if run_with_timeout "$QMD_TIMEOUT_SECONDS" \
    env npm_config_offline=true npm_config_nodedir="$qmd_node_header_root" \
    node "$qmd_node_gyp" rebuild --release --directory="$qmd_better_sqlite" \
    --nodedir="$qmd_node_header_root"; then
    :
  else
    rc=$?
    qmd_command_failed "native rebuild" "$rc"
    rm -rf "$qmd_stage"
    return 0
  fi

  if [[ ! -x "$qmd_stage_bin" ]]; then
    warn "qmd install completed but no executable was found in staging; $(qmd_repair_hint)"
    rm -rf "$qmd_stage"
    return 0
  fi

  if qmd_version="$(run_with_timeout "$QMD_TIMEOUT_SECONDS" \
    "$qmd_stage_bin" --version 2>/dev/null)"; then
    :
  else
    rc=$?
    qmd_command_failed "startup check" "$rc"
    rm -rf "$qmd_stage"
    return 0
  fi

  # `qmd --version` does not import better-sqlite3. Resolve the dependency
  # from QMD's own package root, open an in-memory database, and execute one
  # statement so a stale NODE_MODULE_VERSION cannot be reported as healthy.
  qmd_package_json="${qmd_stage}/lib/node_modules/@tobilu/qmd/package.json"
  if run_with_timeout "$QMD_TIMEOUT_SECONDS" node -e '
    const { createRequire } = require("node:module");
    const qmdRequire = createRequire(process.argv[1]);
    const Database = qmdRequire("better-sqlite3");
    const db = new Database(":memory:");
    db.prepare("SELECT 1").get();
    db.close();
  ' "$qmd_package_json"; then
    :
  else
    rc=$?
    qmd_command_failed "native SQLite health check" "$rc"
    rm -rf "$qmd_stage"
    return 0
  fi

  qmd_backup="$(mktemp -d "${data_home}/.qmd-backup.XXXXXX")"
  rmdir "$qmd_backup"
  qmd_rollback_home="$qmd_home"
  qmd_rollback_backup="$qmd_backup"
  qmd_rollback_stage="$qmd_stage"
  qmd_rollback_had_original=0
  qmd_rollback_armed=1
  if [[ -e "$qmd_home" || -L "$qmd_home" ]]; then
    if ! mv "$qmd_home" "$qmd_backup"; then
      warn "qmd could not preserve the previous managed tree; $(qmd_repair_hint)"
      qmd_rollback_armed=0
      rm -rf "$qmd_stage"
      return 0
    fi
    qmd_had_original=1
    qmd_rollback_had_original=1
  fi
  if ! mv "$qmd_stage" "$qmd_home"; then
    warn "qmd could not activate the verified tree; restoring the previous managed qmd"
    rm -rf "$qmd_home"
    if [[ "$qmd_had_original" -eq 1 ]]; then
      mv "$qmd_backup" "$qmd_home"
    fi
    qmd_rollback_armed=0
    rm -rf "$qmd_stage"
    return 0
  fi
  qmd_rollback_stage=""
  if [[ "$qmd_had_original" -eq 1 ]]; then
    rm -rf "$qmd_backup"
  fi
  qmd_rollback_armed=0

  managed_qmd_canon="$(canonical_existing_path "$qmd_bin")"

  if [[ -e "$qmd_link" || -L "$qmd_link" ]]; then
    existing_qmd_link="$(canonical_existing_path "$qmd_link")"
    if [[ "$existing_qmd_link" != "$managed_qmd_canon" ]]; then
      warn "existing qmd at ${qmd_link}; leaving it unchanged (Hive-managed qmd is ${qmd_bin})"
    else
      ln -sfn "$qmd_bin" "$qmd_link"
    fi
  else
    ln -sfn "$qmd_bin" "$qmd_link"
  fi

  active_qmd="$(command -v qmd 2>/dev/null || true)"
  if [[ -n "$active_qmd" ]]; then
    active_qmd_canon="$(canonical_existing_path "$active_qmd")"
    if [[ -n "$active_qmd_canon" && "$active_qmd_canon" != "$managed_qmd_canon" ]]; then
      warn "PATH resolves qmd to ${active_qmd}, not Hive-managed ${qmd_bin}; wiki refreshes may use the earlier binary"
    fi
  fi

  log "qmd: installed ${qmd_version:-${QMD_NPM_PACKAGE}}"
}

platform="$(detect_platform)"
# Hard-fail BEFORE any network call when the installer itself is
# missing required tools.
installer_preflight
version="${VERSION:-$(latest_version)}"
[[ -n "$version" ]] || die "could not resolve a hive release version"

# A real install already requires Ruby 3.4. Normalize the caller's prefix
# before deriving any install path or writing install-prefix sidecars. Dry-run
# remains dependency-light and writes no sidecar.
if [[ "$DRY_RUN" -ne 1 ]]; then
  ruby_preflight
  if [[ -n "$PREFIX" ]]; then
    PREFIX="$(ruby -e 'print File.expand_path(ARGV.fetch(0))' "$PREFIX")"
  fi
fi

data_base="${PREFIX:-${XDG_DATA_HOME:-${HOME}/.local/share}}"
data_home="${data_base%/}/hive"
gem_home="${data_home}/gems"
bin_home="${XDG_BIN_HOME:-${HOME}/.local/bin}"
gem_file="hive-cli-${version#v}.gem"
release_base="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/${version}"
gem_url="${release_base}/${gem_file}"
checksums_url="${release_base}/SHA256SUMS"
sig_url="${release_base}/SHA256SUMS.sig"
cert_url="${release_base}/SHA256SUMS.pem"
installed_bin="${gem_home}/bin/hive"
hv_installed_bin="${gem_home}/bin/hv"
installed_shim="${gem_home}/shims/hive"
link_path="${bin_home}/hive"
hv_path="${bin_home}/hv"

log "hive install"
log "  version:  ${version}"
log "  platform: ${platform}"
log "  gems:     ${gem_home}"
log "  binary:   ${link_path}"

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "dry run: would download ${gem_url}"
  log "dry run: would verify SHA256SUMS and write ${data_home}/install-channel"
  log "dry run: would gem install --install-dir ${gem_home} ${gem_file}"
  log "dry run: first-run control-plane bootstrap and services remain explicit in hive setup --yes"
  if qmd_install_enabled; then
    log "dry run: would npm ci --ignore-scripts the release-owned QMD dependency lock under ${data_home}/qmd"
    log "dry run: would build better-sqlite3 from locked source with local Node headers"
    log "dry run: would link ${bin_home}/qmd"
  else
    log "dry run: would skip qmd install (HIVE_INSTALL_QMD=${INSTALL_QMD})"
  fi
  runtime_preflight
  exit 0
fi

# RubyGems canonicalizes prerelease versions in install directory names
# (`1.2.3-rc.1` -> `1.2.3.pre.rc.1`). Resolve that spelling before changing
# GEM_HOME so bundled callers and test harnesses cannot affect lookup.
gem_version="$(ruby -rrubygems -e 'print Gem::Version.new(ARGV.fetch(0)).to_s' "${version#v}")"

command -v cosign >/dev/null 2>&1 || die "missing installer prerequisite 'cosign'"

tmpdir="$(mktemp -d)"
launcher_rollback_armed=0
launcher_wrapper_had_original=0
launcher_hv_had_original=0
launcher_shim_had_original=0
launcher_wrapper_backup="${tmpdir}/launcher-hive.backup"
launcher_hv_backup="${tmpdir}/launcher-hv.backup"
launcher_shim_backup="${tmpdir}/launcher-shim.backup"
staged_wrapper=""
staged_hv=""
staged_shim=""
qmd_rollback_armed=0
qmd_rollback_had_original=0
qmd_rollback_home=""
qmd_rollback_backup=""
qmd_rollback_stage=""

restore_launcher_path() {
  local path="$1" had_original="$2" backup="$3"

  rm -f "$path"
  if [[ "$had_original" -eq 1 ]]; then
    cp -pP "$backup" "$path"
  fi
}

cleanup() {
  local rc=$?

  if [[ "$qmd_rollback_armed" -eq 1 ]]; then
    set +e
    rm -rf "$qmd_rollback_home"
    if [[ "$qmd_rollback_had_original" -eq 1 && -e "$qmd_rollback_backup" ]]; then
      mv "$qmd_rollback_backup" "$qmd_rollback_home"
    fi
    warn "qmd activation was interrupted; restored the previous managed tree"
  fi
  if [[ -n "$qmd_rollback_stage" ]]; then
    rm -rf "$qmd_rollback_stage"
  fi

  # Keep recovery armed until all three launcher files are installed and
  # verified. A failure in gem install, shim staging, wrapper construction,
  # chmod, or activation restores the exact pre-install bytes and modes.
  if [[ "$launcher_rollback_armed" -eq 1 ]]; then
    set +e
    restore_launcher_path "$installed_bin" "$launcher_wrapper_had_original" "$launcher_wrapper_backup"
    restore_launcher_path "$hv_installed_bin" "$launcher_hv_had_original" "$launcher_hv_backup"
    restore_launcher_path "$installed_shim" "$launcher_shim_had_original" "$launcher_shim_backup"
    rm -f "$staged_wrapper" "$staged_hv" "$staged_shim"
    warn "launcher update failed; restored the previous wrapper and shim state"
  fi

  rm -rf "$tmpdir"
  trap - EXIT
  exit "$rc"
}

trap cleanup EXIT

download_with_status "$gem_url" "${tmpdir}/${gem_file}" "release gem"
download_with_status "$checksums_url" "${tmpdir}/SHA256SUMS" "SHA256SUMS"

# Authenticate the checksum manifest before trusting its gem or managed-web
# archive digests. Pin the keyless identity to this repository's release
# workflow; a wildcard would accept any GitHub Actions OIDC identity.
download_with_status "$sig_url" "${tmpdir}/SHA256SUMS.sig" "SHA256SUMS.sig"
download_with_status "$cert_url" "${tmpdir}/SHA256SUMS.pem" "SHA256SUMS.pem"
cosign verify-blob \
  --certificate "${tmpdir}/SHA256SUMS.pem" \
  --signature "${tmpdir}/SHA256SUMS.sig" \
  --certificate-identity-regexp "^https://github\\.com/${REPO_OWNER}/${REPO_NAME}/\\.github/workflows/release\\.yml@refs/tags/${version}$" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  "${tmpdir}/SHA256SUMS" \
  || die "cosign verify-blob failed for SHA256SUMS (identity must match ${REPO_OWNER}/${REPO_NAME} release workflow at ${version})"

# Strict line match: optional `./` prefix, sha digest, two-space sep,
# exact gem_file, optional CR. `|| true` so a no-match under `set -e`
# reaches the explicit die below instead of exiting with grep's exit
# 1 and an empty error.
expected_line="$(grep -E "^[a-f0-9]{64}  (\./)?${gem_file}[[:space:]]*$" "${tmpdir}/SHA256SUMS" || true)"
[[ -n "$expected_line" ]] || die "SHA256SUMS does not contain ${gem_file}"

actual="$($(sha256_cmd) "${tmpdir}/${gem_file}" | awk '{print $1}')"
expected="$(printf '%s\n' "$expected_line" | awk '{print $1}')"
[[ "$actual" == "$expected" ]] || die "checksum mismatch for ${gem_file}"

mkdir -p "$bin_home" "$gem_home"

# RubyGems refuses to overwrite the managed bash wrapper left by an earlier
# installer run. Snapshot every launcher path before the first mutation, then
# remove only a wrapper we can identify as ours from the bindir. The EXIT trap
# restores these snapshots until the new wrapper and shim set is verified.
mkdir -p "${gem_home}/bin" "${gem_home}/shims"
if [[ -e "$installed_bin" || -L "$installed_bin" ]]; then
  cp -pP "$installed_bin" "$launcher_wrapper_backup"
  launcher_wrapper_had_original=1
fi
if [[ -e "$hv_installed_bin" || -L "$hv_installed_bin" ]]; then
  cp -pP "$hv_installed_bin" "$launcher_hv_backup"
  launcher_hv_had_original=1
fi
if [[ -e "$installed_shim" || -L "$installed_shim" ]]; then
  cp -pP "$installed_shim" "$launcher_shim_backup"
  launcher_shim_had_original=1
fi
launcher_rollback_armed=1

if [[ -f "$installed_bin" ]] && {
  grep -Fq "hive-managed: install-wrapper/v1" "$installed_bin" ||
    { grep -Fq 'export HIVE_INVOKED_BIN=' "$installed_bin" && grep -Fq '/shims/hive' "$installed_bin"; }
}; then
  rm -f "$installed_bin"
fi

# Install into a dedicated GEM_HOME under ${data_home}/gems. Runtime
# deps (bubbletea, lipgloss, thor, telegram-bot-ruby) are pulled from
# rubygems.org with platform-correct precompiled binaries. --no-document
# skips rdoc/ri generation (saves ~30s on first install).
if ! GEM_HOME="$gem_home" gem install \
  "${tmpdir}/${gem_file}" \
  --install-dir "$gem_home" \
  --bindir "${gem_home}/bin" \
  --no-document \
  --source https://rubygems.org; then
  die "gem install failed for ${gem_file}"
fi

if [[ ! -x "$installed_bin" ]]; then
  die "gem install completed but no executable at ${installed_bin}"
fi

# Write a wrapper at ${gem_home}/bin/hive that sets GEM_HOME/GEM_PATH
# before delegating to the real ruby script. The shim that
# `gem install --bindir` writes uses `require 'rubygems'; gem
# 'hive-cli'` which fails when the user's default GEM_PATH does not
# include $gem_home (which is our common case under XDG_DATA_HOME/hive).
# We replace the shim with a tiny bash wrapper that exports the right
# GEM_PATH before exec'ing the ruby shim under a sub-bindir. This
# keeps the gem-installed scripts intact for `hive update` to refresh. Build
# every replacement beside its destination, then atomically rename it into
# place. Recovery remains armed until the activated set passes verification.
staged_wrapper="${gem_home}/bin/.hive-wrapper.$$"
staged_hv="${gem_home}/bin/.hv-wrapper.$$"
staged_shim="${gem_home}/shims/.hive-shim.$$"
mv "${gem_home}/bin/hive" "$staged_shim"
cat > "$staged_wrapper" <<WRAPPER
#!/usr/bin/env bash
# hive-managed: install-wrapper/v1
export GEM_HOME="${gem_home}"
export GEM_PATH="\${GEM_HOME}\${GEM_PATH:+:\$GEM_PATH}"
export HIVE_INVOKED_BIN="\${HIVE_INVOKED_BIN:-\$0}"
exec "${gem_home}/shims/hive" "\$@"
WRAPPER
cat > "$staged_hv" <<WRAPPER
#!/usr/bin/env bash
export GEM_HOME="${gem_home}"
export GEM_PATH="\${GEM_HOME}\${GEM_PATH:+:\$GEM_PATH}"
export HIVE_INVOKED_BIN="\${HIVE_INVOKED_BIN:-\$0}"
exec "${gem_home}/bin/hive" "\$@"
WRAPPER
chmod +x "$staged_shim" "$staged_wrapper" "$staged_hv"
bash -n "$staged_wrapper" "$staged_hv"
grep -Fq "hive-managed: install-wrapper/v1" "$staged_wrapper"

mv -f "$staged_shim" "$installed_shim"
staged_shim=""
mv -f "$staged_wrapper" "$installed_bin"
staged_wrapper=""
mv -f "$staged_hv" "$hv_installed_bin"
staged_hv=""

[[ -x "$installed_shim" ]] || die "installed hive shim is not executable at ${installed_shim}"
[[ -x "$installed_bin" ]] || die "installed hive wrapper is not executable at ${installed_bin}"
[[ -x "$hv_installed_bin" ]] || die "installed hv wrapper is not executable at ${hv_installed_bin}"
bash -n "$installed_bin" "$hv_installed_bin"
grep -Fq "hive-managed: install-wrapper/v1" "$installed_bin"
launcher_rollback_armed=0

install_qmd

existing_hive="$(command -v hive 2>/dev/null || true)"
existing_canon=""
if [[ -n "$existing_hive" ]]; then
  existing_canon="$(readlink -f "$existing_hive" 2>/dev/null || true)"
fi

# Publish a user-facing launcher only when the destination is absent or is the
# exact absolute symlink this installer previously created. `ln -sfn` removes
# an existing regular file (and can replace an unrelated symlink), so using it
# without this ownership check would destroy an operator's launcher before the
# Apache-Hive collision fallback had a chance to select `hv`.
publish_managed_link() {
  local path="$1" target="$2" name="$3" current_target

  if [[ ! -e "$path" && ! -L "$path" ]]; then
    ln -s "$target" "$path" || return 1
    return 0
  fi

  if [[ -L "$path" ]]; then
    current_target="$(readlink "$path" 2>/dev/null || true)"
    if [[ "$current_target" == "$target" ]]; then
      return 0
    fi
  fi

  warn "existing ${name} at ${path}; leaving it unchanged"
  return 1
}

# Write marker BEFORE swapping the symlink so any concurrent `hive`
# invocation reads the new channel rather than falling through to
# `dev` during the brief gap. Write under `data_home` (the install
# location, possibly under `--prefix`) AND under the XDG default
# when `--prefix` is non-default — `hive update` reads the XDG path
# without re-exporting `HIVE_PREFIX`, so dropping a marker there
# preserves channel detection across shells. The marker payload is
# the channel name; when --prefix is set we ALSO write a sidecar
# `install-prefix` so InstallChannel can re-derive the prefix.
printf 'bash\n' > "${data_home}/install-channel"
if [[ -n "$PREFIX" ]]; then
  printf '%s\n' "$PREFIX" > "${data_home}/install-prefix"
  xdg_data_home="${XDG_DATA_HOME:-${HOME}/.local/share}/hive"
  if [[ "$xdg_data_home" != "$data_home" ]]; then
    mkdir -p "$xdg_data_home"
    printf 'bash\n' > "${xdg_data_home}/install-channel"
    printf '%s\n' "$PREFIX" > "${xdg_data_home}/install-prefix"
  fi
fi

managed_hive_canon="$(readlink -f "${gem_home}/bin/hive" 2>/dev/null || echo "${gem_home}/bin/hive")"
hive_link_published=0
if publish_managed_link "$link_path" "${gem_home}/bin/hive" "hive"; then
  hive_link_published=1
fi

if [[ "$hive_link_published" -ne 1 ]] ||
   { [[ -n "$existing_hive" ]] && [[ -n "$existing_canon" ]] &&
     [[ "$existing_canon" != "$managed_hive_canon" ]]; }; then
  if publish_managed_link "$hv_path" "${gem_home}/bin/hv" "hv"; then
    if [[ "$hive_link_published" -ne 1 ]]; then
      warn "installed hv fallback at ${hv_path}; ${link_path} remains operator-owned"
    else
      warn "existing hive on PATH at ${existing_hive}; installed hv fallback at ${hv_path}"
    fi
  else
    warn "Hive launchers remain available under ${gem_home}/bin"
  fi
else
  # The hive launcher is published and unconflicted, but hv must still exist
  # as the Apache Hive collision fallback: create it when absent, refresh it
  # when it is ours (so stale symlinks from earlier installs don't dangle),
  # and back off only when another program owns the name — matching the qmd
  # managed-link behavior above.
  publish_managed_link "$hv_path" "${gem_home}/bin/hv" "hv" || true
fi

runtime_preflight

log "installed hive ${version} (hive-cli rubygem)"
log "next: run 'hive --version', then 'hive setup --yes' to bootstrap runtime state and services"
log "agent skills are installed separately; see install.md"
