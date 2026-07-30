#!/usr/bin/env bash
set -euo pipefail

REPO_OWNER="${HIVE_REPO_OWNER:-ivankuznetsov}"
REPO_NAME="${HIVE_REPO_NAME:-hive}"
DRY_RUN=0
VERSION="${HIVE_VERSION:-}"
PREFIX="${HIVE_PREFIX:-}"
INSTALL_QMD="${HIVE_INSTALL_QMD:-1}"
QMD_NPM_PACKAGE="${HIVE_QMD_NPM_PACKAGE:-@tobilu/qmd}"
ROOT_INSTALL=0
PREFIX_OPTION_SEEN=0
RUBY_COMMAND="ruby"
GEM_COMMAND="gem"

usage() {
  cat <<USAGE
usage: install.sh [--dry-run] [--prefix=<dir>] [--version=<tag>]

Installs hive as a rubygem (\`hive-cli\`) from GitHub Releases. The .gem
is signed with cosign keyless attestation against this repo's release
workflow; verification always fails closed when cosign is unavailable.

After install the \`hive\` and \`hv\` executables are symlinked into
\${XDG_BIN_HOME:-~/.local/bin}; a root install defaults to
\`/usr/local/bin\` with its managed gems under \`/usr/local/share/hive\`.
The installer also runs \`hive daemon install\`
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
  HIVE_QMD_NPM_PACKAGE  Override the npm package spec used for the QMD
                        install; defaults to \`@tobilu/qmd\`.
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

root_install_guard() {
  local name
  [[ "$EUID" -eq 0 ]] || return 0

  ROOT_INSTALL=1
  if [[ "$PREFIX_OPTION_SEEN" -eq 1 || -n "$PREFIX" ]]; then
    die "root installation uses the fixed /usr/local Hive layout; --prefix and HIVE_PREFIX are not accepted"
  fi
  for name in \
    HIVE_HOME XDG_BIN_HOME XDG_CACHE_HOME XDG_CONFIG_HOME XDG_DATA_HOME \
    XDG_STATE_HOME RUBYOPT RUBYLIB GEM_HOME GEM_PATH RUBYGEMS_GEMDEPS \
    BUNDLE_PATH BUNDLE_GEMFILE BUNDLE_BIN_PATH BUNDLE_USER_HOME \
    RBENV_ROOT RBENV_VERSION MISE_DATA_DIR MISE_CONFIG_DIR ASDF_DIR \
    LD_PRELOAD LD_LIBRARY_PATH DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH \
    BASH_ENV ENV CDPATH TMPDIR HIVE_REPO_OWNER HIVE_REPO_NAME \
    HIVE_QMD_NPM_PACKAGE; do
    if declare -p "$name" >/dev/null 2>&1; then
      die "root installation refuses inherited ${name}; use the fixed system channel"
    fi
  done
  PATH="/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin"
  export PATH
  INSTALL_QMD=0
  RUBY_COMMAND="/usr/bin/ruby"
  GEM_COMMAND="/usr/bin/gem"
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
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      ;;
    --prefix=*)
      PREFIX_OPTION_SEEN=1
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

root_install_guard
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
  for dep in "$RUBY_COMMAND" "$GEM_COMMAND"; do
    if [[ ! -x "$dep" ]] && ! command -v "$dep" >/dev/null 2>&1; then
      warn "missing installer prerequisite '${dep}' (install Ruby 3.4 with rbenv / mise / asdf, or your OS package manager)"
      missing=1
    fi
  done
  if [[ "$missing" -ne 0 ]]; then
    die "install aborted: Ruby 3.4 is required — fix the warnings above and re-run"
  fi
  if ! "$RUBY_COMMAND" -e 'exit(RUBY_VERSION.to_f >= 3.4)' 2>/dev/null; then
    die "Ruby 3.4+ required; found $("$RUBY_COMMAND" -e 'print RUBY_VERSION' 2>/dev/null || echo unknown)"
  fi
}

root_owned_immutable_path() {
  local path="$1" parent leaf canonical_parent canonical owner mode numeric_mode
  [[ "$path" == /* ]] ||
    die "root system channel requires an absolute path at ${path}"
  [[ -e "$path" && ! -L "$path" ]] ||
    die "root system channel requires a non-symlink path at ${path}"
  parent="${path%/*}"
  leaf="${path##*/}"
  [[ -n "$parent" && -n "$leaf" ]] ||
    die "root system channel cannot canonicalize path ${path}"
  canonical_parent="$(CDPATH='' cd -P "$parent" && pwd -P)"
  canonical="${canonical_parent%/}/${leaf}"
  [[ "$canonical" == "$path" ]] ||
    die "root system channel refuses redirected path ${path}"
  if [[ "$(uname -s)" == "Darwin" ]]; then
    owner="$(stat -f '%u' "$path")"
    mode="$(stat -f '%Lp' "$path")"
  else
    owner="$(stat -c '%u' "$path")"
    mode="$(stat -c '%a' "$path")"
  fi
  numeric_mode=$((8#$mode))
  [[ "$owner" -eq 0 && $((numeric_mode & 8#022)) -eq 0 ]] ||
    die "root system channel path is not root-owned and immutable: ${path}"
}

root_system_preflight() {
  [[ "$ROOT_INSTALL" -eq 1 ]] || return 0
  root_owned_immutable_path "/usr/local"
  [[ ! -e /usr/local/share ]] ||
    root_owned_immutable_path "/usr/local/share"
  root_owned_immutable_path "/usr/local/bin"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    root_owned_immutable_path "$RUBY_COMMAND"
    root_owned_immutable_path "$GEM_COMMAND"
    ruby_preflight
  fi
}

root_installer_tool_preflight() {
  local tool resolved
  [[ "$ROOT_INSTALL" -eq 1 && "$DRY_RUN" -eq 0 ]] || return 0
  for tool in curl jq cosign; do
    resolved="$(command -v "$tool" 2>/dev/null || true)"
    [[ -n "$resolved" ]] ||
      die "root system channel is missing trusted installer tool ${tool}"
    root_owned_immutable_path "$resolved"
  done
  resolved="$(command -v sha256sum 2>/dev/null || command -v shasum 2>/dev/null || true)"
  [[ -n "$resolved" ]] ||
    die "root system channel is missing a trusted checksum tool"
  root_owned_immutable_path "$resolved"
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

# Hive's daemon is global user infrastructure. Project setup later only
# controls whether a project is enrolled for dispatch; the service itself
# should already be installed, enabled, and started after Hive is installed.
daemon_autostart_setup() {
  local out err rc outcome
  out="${tmpdir}/daemon-install.out"
  err="${tmpdir}/daemon-install.err"

  if "$link_path" daemon install --json >"$out" 2>"$err"; then
    # `jq -e` fails when the envelope is unparseable or `.outcome` is
    # absent/null, so a garbled-but-exit-0 install is reported instead
    # of being silently trusted as success.
    if outcome="$(jq -er '.outcome' "$out" 2>/dev/null)"; then
      case "$outcome" in
        written|upgraded|unchanged)
          log "daemon autostart enabled via hive daemon install (${outcome})"
          ;;
        unsupported)
          # Known-platform limitation (e.g. Linux without systemd-user):
          # the unit was written but autostart could not be enabled. The
          # CLI exits 0 for this, so it is not a failure to warn about.
          log "daemon unit written; autostart unavailable on this host (hive daemon install: unsupported)"
          ;;
        *)
          warn "daemon autostart setup reported outcome '${outcome}'; Hive is installed, but the daemon may not start after reboot"
          ;;
      esac
    else
      warn "daemon autostart setup succeeded but its JSON output was unreadable; Hive is installed, but the daemon may not start after reboot"
      if [[ -s "$out" ]]; then
        sed 's/^/hive install: daemon output: /' "$out" >&2
      fi
    fi
    if jq -e '.messages? | length > 0' "$out" >/dev/null 2>&1; then
      jq -r '.messages[]?' "$out" | sed 's/^/hive install: daemon message: /' >&2
    fi
    return 0
  else
    # `rc=$?` is the first statement in the else branch, so it captures
    # the exit code of the failed `hive daemon install` (NOT 0 — `$?`
    # after a false `if` condition with no else would be 0).
    rc=$?
    warn "daemon autostart setup did not complete (exit ${rc}); Hive is installed, but the daemon may not start after reboot"
    warn "run '${link_path} daemon install' after fixing launchd/systemd-user, or '${link_path} daemon install --force' if an existing unit is customized"
    if [[ -s "$err" ]]; then
      sed 's/^/hive install: daemon stderr: /' "$err" >&2
    fi
    if [[ -s "$out" ]]; then
      sed 's/^/hive install: daemon output: /' "$out" >&2
    fi
    return 0
  fi
}

job_schema_migration_setup() {
  local out err rc
  local -a migration_args
  local migration_scope="current-user"
  out="${tmpdir}/job-schema-migration.out"
  err="${tmpdir}/job-schema-migration.err"
  migration_args=(refactor-patrol-migrate-installed)
  if [[ "$(id -u)" -eq 0 ]]; then
    migration_args+=(--all-users --ensure-retry-service)
    migration_scope="all-users"
  fi

  if "$link_path" "${migration_args[@]}" >"$out" 2>"$err"; then
    log "registered-project JobStore migration completed (${migration_scope})"
    if [[ "$migration_scope" == "current-user" ]]; then
      warn "shared installation coverage is not complete; use a root-owned system package to run the install-wide migration (never elevate this user-prefix Hive)"
    fi
    return 0
  else
    rc=$?
    warn "registered-project JobStore migration did not complete (exit ${rc}); inspect the emitted receipt and use a root-owned system package for shared installations"
    if [[ -s "$err" ]]; then
      sed 's/^/hive install: migration stderr: /' "$err" >&2
    fi
    if [[ -s "$out" ]]; then
      sed 's/^/hive install: migration output: /' "$out" >&2
    fi
    return 0
  fi
}

qmd_install_enabled() {
  case "$INSTALL_QMD" in
    0|false|False|FALSE|no|No|NO) return 1 ;;
    *) return 0 ;;
  esac
}

qmd_repair_hint() {
  local qmd_home_arg="$1"
  printf 'rerun hive update, or run: npm install --global --prefix %q %q' "$qmd_home_arg" "$QMD_NPM_PACKAGE"
}

# Install the qmd CLI used by Hive-managed llm-wiki refresh scripts into
# Hive's own data prefix. This keeps the native better-sqlite3 build out
# of the user's global npm prefix while still making `qmd` available from
# the same bin directory as `hive`.
install_qmd() {
  local qmd_home qmd_bin qmd_link existing_qmd_link managed_qmd_link active_qmd active_qmd_canon managed_qmd_canon qmd_version
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

  log "qmd: installing ${QMD_NPM_PACKAGE} into ${qmd_home}"
  mkdir -p "$qmd_home"
  if ! npm install --global --prefix "$qmd_home" --no-audit --no-fund "$QMD_NPM_PACKAGE"; then
    warn "qmd install failed; $(qmd_repair_hint "$qmd_home")"
    return 0
  fi

  # `npm install` may leave an existing native better-sqlite3 build in place
  # after a Node upgrade. Rebuild explicitly so `hive update` repairs the
  # NODE_MODULE_VERSION mismatch class of failures.
  npm rebuild --global --prefix "$qmd_home" better-sqlite3 >/dev/null 2>&1 || true

  if [[ ! -x "$qmd_bin" ]]; then
    warn "qmd install completed but no executable was found at ${qmd_bin}; $(qmd_repair_hint "$qmd_home")"
    return 0
  fi

  if ! "$qmd_bin" --version >/dev/null 2>&1; then
    warn "qmd installed at ${qmd_bin} but failed to start; $(qmd_repair_hint "$qmd_home")"
    return 0
  fi

  if [[ -e "$qmd_link" || -L "$qmd_link" ]]; then
    existing_qmd_link="$(readlink -f "$qmd_link" 2>/dev/null || true)"
    managed_qmd_link="$(readlink -f "$qmd_bin" 2>/dev/null || echo "$qmd_bin")"
    if [[ "$existing_qmd_link" != "$managed_qmd_link" ]]; then
      warn "existing qmd at ${qmd_link}; leaving it unchanged (Hive-managed qmd is ${qmd_bin})"
    else
      ln -sfn "$qmd_bin" "$qmd_link"
    fi
  else
    ln -sfn "$qmd_bin" "$qmd_link"
  fi

  active_qmd="$(command -v qmd 2>/dev/null || true)"
  if [[ -n "$active_qmd" ]]; then
    active_qmd_canon="$(readlink -f "$active_qmd" 2>/dev/null || true)"
    managed_qmd_canon="$(readlink -f "$qmd_bin" 2>/dev/null || echo "$qmd_bin")"
    if [[ -n "$active_qmd_canon" && "$active_qmd_canon" != "$managed_qmd_canon" ]]; then
      warn "PATH resolves qmd to ${active_qmd}, not Hive-managed ${qmd_bin}; wiki refreshes may use the earlier binary"
    fi
  fi

  qmd_version="$("$qmd_bin" --version 2>/dev/null || true)"
  log "qmd: installed ${qmd_version:-${QMD_NPM_PACKAGE}}"
}

root_system_preflight
platform="$(detect_platform)"
# Hard-fail BEFORE any network call when the installer itself is
# missing required tools.
installer_preflight
root_installer_tool_preflight
version="${VERSION:-$(latest_version)}"
[[ -n "$version" ]] || die "could not resolve a hive release version"

if [[ "$ROOT_INSTALL" -eq 1 ]]; then
  data_base="/usr/local/share"
  bin_home="/usr/local/bin"
else
  data_base="${PREFIX:-${XDG_DATA_HOME:-${HOME}/.local/share}}"
  bin_home="${XDG_BIN_HOME:-${HOME}/.local/bin}"
fi
if [[ "$(id -u)" -eq 0 ]]; then
  # Every discovered account must be able to traverse and load the candidate
  # runtime after the coordinator drops privileges.
  umask 022
fi
data_home="${data_base%/}/hive"
gem_home="${data_home}/gems"
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
  if [[ "$(id -u)" -eq 0 ]]; then
    log "dry run: would migrate every project for every discovered/inventoried Hive user"
  else
    log "dry run: would migrate only the installing user's Hive registry; shared installs require the administrator all-user command"
  fi
  log "dry run: would run ${link_path} daemon install to enable daemon autostart"
  if qmd_install_enabled; then
    log "dry run: would npm install --global --prefix ${data_home}/qmd ${QMD_NPM_PACKAGE}"
    log "dry run: would npm rebuild --global --prefix ${data_home}/qmd better-sqlite3"
    log "dry run: would link ${bin_home}/qmd"
  else
    log "dry run: would skip qmd install (HIVE_INSTALL_QMD=${INSTALL_QMD})"
  fi
  runtime_preflight
  exit 0
fi

# Probe Ruby/gem now that we know this is not a dry-run; the gem
# install path requires Ruby 3.4 on PATH.
if [[ "$ROOT_INSTALL" -eq 0 ]]; then
  ruby_preflight
fi
command -v cosign >/dev/null 2>&1 || die "missing installer prerequisite 'cosign'"

if [[ "$ROOT_INSTALL" -eq 1 ]]; then
  tmpdir="$(mktemp -d /var/tmp/hive-install.XXXXXXXX)"
else
  tmpdir="$(mktemp -d)"
fi
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

restore_launcher_path() {
  local path="$1" had_original="$2" backup="$3"

  rm -f "$path"
  if [[ "$had_original" -eq 1 ]]; then
    cp -pP "$backup" "$path"
  fi
}

cleanup() {
  local rc=$?

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
  --certificate-identity-regexp "^https://github\\.com/${REPO_OWNER}/${REPO_NAME}/\\.github/workflows/release\\.yml@refs/tags/${VERSION}$" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  "${tmpdir}/SHA256SUMS" \
  || die "cosign verify-blob failed for SHA256SUMS (identity must match ${REPO_OWNER}/${REPO_NAME} release workflow at ${VERSION})"

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
if ! GEM_HOME="$gem_home" "$GEM_COMMAND" install \
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
root_runtime_manifest="${data_home}/root-runtime.json"
if [[ "$ROOT_INSTALL" -eq 1 ]]; then
cat > "$staged_wrapper" <<WRAPPER
#!/bin/bash
# hive-managed: install-wrapper/v1
unset RUBYOPT RUBYLIB RUBYGEMS_GEMDEPS BUNDLE_PATH BUNDLE_GEMFILE BUNDLE_BIN_PATH
export GEM_HOME="${gem_home}"
export GEM_PATH="${gem_home}"
export HIVE_INVOKED_BIN="${installed_bin}"
export HIVE_ROOT_RUNTIME_LAUNCHER=1
export HIVE_ROOT_RUNTIME_MANIFEST="${root_runtime_manifest}"
if [[ "\$EUID" -eq 0 ]]; then
  exec /usr/bin/env -i HOME=/root USER=root LOGNAME=root PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin LANG=C.UTF-8 GEM_HOME="${gem_home}" GEM_PATH="${gem_home}" HIVE_INVOKED_BIN="${installed_bin}" HIVE_ROOT_RUNTIME_LAUNCHER=1 HIVE_ROOT_RUNTIME_MANIFEST="${root_runtime_manifest}" "${RUBY_COMMAND}" "${installed_shim}" "\$@"
fi
exec "${RUBY_COMMAND}" "${installed_shim}" "\$@"
WRAPPER
else
cat > "$staged_wrapper" <<WRAPPER
#!/usr/bin/env bash
# hive-managed: install-wrapper/v1
export GEM_HOME="${gem_home}"
export GEM_PATH="\${GEM_HOME}\${GEM_PATH:+:\$GEM_PATH}"
export HIVE_INVOKED_BIN="\${HIVE_INVOKED_BIN:-\$0}"
exec "${gem_home}/shims/hive" "\$@"
WRAPPER
fi
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

if [[ "$(id -u)" -eq 0 ]]; then
  chmod -R go-w,a+rX "$gem_home"
  chmod 0755 "$installed_shim" "$installed_bin" "$hv_installed_bin"
fi
if [[ "$ROOT_INSTALL" -eq 1 ]]; then
  printf '{"gem_home":"%s","launcher":"%s","ruby":"%s","schema":"hive-root-runtime","schema_version":1,"script":"%s"}' \
    "$gem_home" "$installed_bin" "$RUBY_COMMAND" "$installed_shim" \
    > "${root_runtime_manifest}.tmp"
  chmod 0644 "${root_runtime_manifest}.tmp"
  mv -f "${root_runtime_manifest}.tmp" "$root_runtime_manifest"
fi
launcher_rollback_armed=0

install_qmd

existing_hive="$(command -v hive 2>/dev/null || true)"
existing_canon=""
if [[ -n "$existing_hive" ]]; then
  existing_canon="$(readlink -f "$existing_hive" 2>/dev/null || true)"
fi
link_canon=""
if [[ -e "$link_path" ]]; then
  link_canon="$(readlink -f "$link_path" 2>/dev/null || true)"
fi

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
ln -sfn "${gem_home}/bin/hive" "$link_path"

if [[ -n "$existing_hive" ]] && [[ -n "$existing_canon" ]] && [[ "$existing_canon" != "$link_canon" ]] && [[ "$existing_canon" != "$(readlink -f "${gem_home}/bin/hive" 2>/dev/null || echo "${gem_home}/bin/hive")" ]]; then
  ln -sfn "${gem_home}/bin/hv" "$hv_path"
  warn "existing hive on PATH at ${existing_hive}; installed hv fallback at ${hv_path}"
else
  # Always refresh hv when we already own it so stale symlinks from
  # earlier installs don't dangle.
  if [[ -L "$hv_path" ]]; then
    ln -sfn "${gem_home}/bin/hv" "$hv_path"
  fi
fi

runtime_preflight
job_schema_migration_setup
if [[ "$ROOT_INSTALL" -eq 0 ]]; then
  daemon_autostart_setup
fi

log "installed hive ${version} (hive-cli rubygem)"
log "next: run 'hive --version', then 'hive init' in a project to enroll it for daemon dispatch"
log "agent skills are installed separately; see install.md"
