#!/usr/bin/env bash
set -euo pipefail

REPO_OWNER="${HIVE_REPO_OWNER:-ivankuznetsov}"
REPO_NAME="${HIVE_REPO_NAME:-hive}"
DRY_RUN=0
VERSION="${HIVE_VERSION:-}"
PREFIX="${HIVE_PREFIX:-}"
INSTALL_QMD="${HIVE_INSTALL_QMD:-1}"
QMD_NPM_PACKAGE="${HIVE_QMD_NPM_PACKAGE:-@tobilu/qmd}"

usage() {
  cat <<USAGE
usage: install.sh [--dry-run] [--prefix=<dir>] [--version=<tag>]

Installs hive as a rubygem (\`hive-cli\`) from GitHub Releases. The .gem
is signed with cosign keyless attestation against this repo's release
workflow; verification fails closed when cosign is available.

After install the \`hive\` and \`hv\` executables are symlinked into
\${XDG_BIN_HOME:-~/.local/bin}. The installer also runs \`hive daemon install\`
to write and enable the per-user daemon autostart unit when the host supports
it. The gem and its runtime dependencies (bubbletea, lipgloss, thor,
telegram-bot-ruby) live under \${HIVE_PREFIX:-~/.local/share}/hive/gems so an
uninstall is a clean \`rm -rf\` plus symlink removal.

Requires Ruby 3.4 already on PATH; the installer reports its own
prereqs (\`curl\`, \`jq\`, checksum tool) on first run. When npm is
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

platform="$(detect_platform)"
# Hard-fail BEFORE any network call when the installer itself is
# missing required tools.
installer_preflight
version="${VERSION:-$(latest_version)}"
[[ -n "$version" ]] || die "could not resolve a hive release version"

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
ruby_preflight

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

download_with_status "$gem_url" "${tmpdir}/${gem_file}" "release gem"
download_with_status "$checksums_url" "${tmpdir}/SHA256SUMS" "SHA256SUMS"

# Cosign verify SHA256SUMS when both the signature blob and the
# keyless cert are published — release.yml writes both. We skip the
# verification only when cosign isn't installed; missing signature
# files are an attestable regression and we fail closed.
if command -v cosign >/dev/null 2>&1; then
  download_with_status "$sig_url" "${tmpdir}/SHA256SUMS.sig" "SHA256SUMS.sig"
  download_with_status "$cert_url" "${tmpdir}/SHA256SUMS.pem" "SHA256SUMS.pem"
  # Pin the keyless identity to OUR release workflow rather than `.*`.
  # `.*` regexps would accept any GHA OIDC token from any repo —
  # neutering the signature check. The identity must match the
  # release.yml workflow path under ivankuznetsov/hive (allowing
  # forks under HIVE_REPO_OWNER/HIVE_REPO_NAME via env). The issuer
  # is GitHub Actions' Fulcio OIDC endpoint.
  cosign verify-blob \
    --certificate "${tmpdir}/SHA256SUMS.pem" \
    --signature "${tmpdir}/SHA256SUMS.sig" \
    --certificate-identity-regexp "^https://github\\.com/${REPO_OWNER}/${REPO_NAME}/" \
    --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
    "${tmpdir}/SHA256SUMS" \
    || die "cosign verify-blob failed for SHA256SUMS (identity must match ${REPO_OWNER}/${REPO_NAME} release workflow)"
else
  # Phrased as a positive info line, not a scare-warning: the SHA256 check still
  # runs (see below). cosign is an optional second factor for keyless signature
  # verification — installing it upgrades the check; not having it doesn't break
  # the install.
  log "verifying release with SHA256 (install cosign for additional keyless signature verification)"
fi

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

# Install into a dedicated GEM_HOME under ${data_home}/gems. Runtime
# deps (bubbletea, lipgloss, thor, telegram-bot-ruby) are pulled from
# rubygems.org with platform-correct precompiled binaries. --no-document
# skips rdoc/ri generation (saves ~30s on first install).
GEM_HOME="$gem_home" gem install \
  "${tmpdir}/${gem_file}" \
  --install-dir "$gem_home" \
  --bindir "${gem_home}/bin" \
  --no-document \
  --source https://rubygems.org \
  || die "gem install failed for ${gem_file}"

[[ -x "$installed_bin" ]] || die "gem install completed but no executable at ${installed_bin}"

# Write a wrapper at ${gem_home}/bin/hive that sets GEM_HOME/GEM_PATH
# before delegating to the real ruby script. The shim that
# `gem install --bindir` writes uses `require 'rubygems'; gem
# 'hive-cli'` which fails when the user's default GEM_PATH does not
# include $gem_home (which is our common case under XDG_DATA_HOME/hive).
# We replace the shim with a tiny bash wrapper that exports the right
# GEM_PATH before exec'ing the ruby shim under a sub-bindir. This
# keeps the gem-installed scripts intact for `hive update` to refresh.
mkdir -p "${gem_home}/shims"
mv "${gem_home}/bin/hive" "${gem_home}/shims/hive"
mv "${gem_home}/bin/hv" "${gem_home}/shims/hv"
cat > "${gem_home}/bin/hive" <<WRAPPER
#!/usr/bin/env bash
export GEM_HOME="${gem_home}"
export GEM_PATH="\${GEM_HOME}\${GEM_PATH:+:\$GEM_PATH}"
export HIVE_INVOKED_BIN="\${HIVE_INVOKED_BIN:-\$0}"
exec "${gem_home}/shims/hive" "\$@"
WRAPPER
cat > "${gem_home}/bin/hv" <<WRAPPER
#!/usr/bin/env bash
export GEM_HOME="${gem_home}"
export GEM_PATH="\${GEM_HOME}\${GEM_PATH:+:\$GEM_PATH}"
export HIVE_INVOKED_BIN="\${HIVE_INVOKED_BIN:-\$0}"
exec "${gem_home}/bin/hive" "\$@"
WRAPPER
chmod +x "${gem_home}/bin/hive" "${gem_home}/bin/hv"

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
daemon_autostart_setup

log "installed hive ${version} (hive-cli rubygem)"
log "next: run 'hive --version', then 'hive init' in a project to enroll it for daemon dispatch"
log "agent skills are installed separately; see install.md"
