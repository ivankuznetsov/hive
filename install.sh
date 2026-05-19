#!/usr/bin/env bash
set -euo pipefail

REPO_OWNER="${HIVE_REPO_OWNER:-ivankuznetsov}"
REPO_NAME="${HIVE_REPO_NAME:-hive}"
DRY_RUN=0
VERSION="${HIVE_VERSION:-}"
PREFIX="${HIVE_PREFIX:-}"

usage() {
  cat <<USAGE
usage: install.sh [--dry-run] [--prefix=<dir>] [--version=<tag>]

Installs hive from GitHub Releases into XDG user paths.
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

detect_target() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"

  case "$os" in
    Darwin)
      [[ "$arch" == "arm64" ]] || die "unsupported platform: macOS ${arch}; tier-1 binary is darwin-arm64"
      printf 'darwin-arm64\n'
      ;;
    Linux)
      # Detect musl by probing for the dynamic linker symlink — `ldd`
      # is missing on minimal containers (distroless, CI bases) where
      # glibc is still present, so absent-ldd should not by itself
      # poison the tier-1 result. The presence of `/lib/ld-musl-*`
      # (or any musl interpreter) is the authoritative signal.
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
      die "unsupported platform: ${os}; tier-1 targets are macOS arm64, Ubuntu 22.04+, and Arch Linux"
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
# crashing mid-curl / mid-tar with a confusing trace. `tar`, `mktemp`,
# `mv`, `rm`, and `ln` come from coreutils and are assumed present.
# `sha256sum`/`shasum` is probed separately via `sha256_cmd`.
installer_preflight() {
  local dep missing=0
  for dep in curl jq tar; do
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

# Warn-only check for runtime tools the installed binary uses at run
# time (`hive run`, `hive doctor`, agent CLIs). Per plan U2 these are
# never auto-installed; missing them does NOT fail the installer —
# the binary on disk is already valid and `hive --version`,
# `hive doctor`, and `hive update` keep working.
runtime_preflight() {
  local dep
  for dep in git bash claude gh; do
    if ! command -v "$dep" >/dev/null 2>&1; then
      warn "missing runtime dependency '${dep}' — install with: $(install_hint "$dep")"
    fi
  done
}

target="$(detect_target)"
# Hard-fail BEFORE any network call when the installer itself is
# missing required tools — `latest_version` shells out to jq, the
# download path shells out to tar / sha256sum, etc.
installer_preflight
version="${VERSION:-$(latest_version)}"
[[ -n "$version" ]] || die "could not resolve a hive release version"

data_base="${PREFIX:-${XDG_DATA_HOME:-${HOME}/.local/share}}"
data_home="${data_base%/}/hive"
bin_home="${XDG_BIN_HOME:-${HOME}/.local/bin}"
archive_name="hive-${version#v}-${target}.tar.gz"
release_base="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/${version}"
archive_url="${release_base}/${archive_name}"
checksums_url="${release_base}/SHA256SUMS"
sig_url="${release_base}/SHA256SUMS.sig"
cert_url="${release_base}/SHA256SUMS.pem"
install_dir="${data_home}/${version}"
installed_bin="${install_dir}/bin/hive"
link_path="${bin_home}/hive"
hv_path="${bin_home}/hv"

log "hive install"
log "  version: ${version}"
log "  target:  ${target}"
log "  install: ${install_dir}"
log "  binary:  ${link_path}"

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "dry run: would download ${archive_url}"
  log "dry run: would verify SHA256SUMS and write ${data_home}/install-channel"
  runtime_preflight
  exit 0
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

download_with_status "$archive_url" "${tmpdir}/${archive_name}" "release tarball"
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
  warn "cosign not installed; skipping signature verification (still validating SHA256)"
fi

# Strict line match: optional `./` prefix, sha digest, two-space sep,
# exact archive_name, optional CR. `|| true` so a no-match under
# `set -e` reaches the explicit die below instead of exiting with
# grep's exit 1 and an empty error.
expected_line="$(grep -E "^[a-f0-9]{64}  (\./)?${archive_name}[[:space:]]*$" "${tmpdir}/SHA256SUMS" || true)"
[[ -n "$expected_line" ]] || die "SHA256SUMS does not contain ${archive_name}"

actual="$($(sha256_cmd) "${tmpdir}/${archive_name}" | awk '{print $1}')"
expected="$(printf '%s\n' "$expected_line" | awk '{print $1}')"
[[ "$actual" == "$expected" ]] || die "checksum mismatch for ${archive_name}"

mkdir -p "$bin_home" "$data_home"
tar -xzf "${tmpdir}/${archive_name}" -C "$tmpdir"
extracted="${tmpdir}/hive-${version#v}-${target}"
[[ -x "${extracted}/bin/hive" ]] || die "release archive does not contain executable bin/hive"

# Atomic swap: stage under `${install_dir}.new` (sibling of the live
# install dir so the rename is a directory-rename on the same fs),
# move the live one out of the way under `.old`, then rename
# `.new` → live and reap `.old`. A concurrent `hive` invocation
# always sees either the previous or the next install_dir tree, never
# a partially-extracted directory.
staged_dir="${install_dir}.new"
old_dir="${install_dir}.old"
rm -rf "$staged_dir" "$old_dir"
mkdir -p "$(dirname "$install_dir")"
mv "$extracted" "$staged_dir"
if [[ -e "$install_dir" ]]; then
  mv -T "$install_dir" "$old_dir"
fi
mv -T "$staged_dir" "$install_dir"
rm -rf "$old_dir"

if [[ "$(uname -s)" == "Darwin" ]] && command -v xattr >/dev/null 2>&1; then
  # Treat any xattr failure as benign — Gatekeeper quarantine removal
  # is best-effort and not all entries carry the attribute.
  xattr -d com.apple.quarantine "$installed_bin" || true
fi

existing_hive="$(command -v hive 2>/dev/null || true)"
# Use realpath to compare canonical locations without `cd`, which under
# set -e would abort the script if the directory of the colliding
# binary became unreadable mid-install.
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
ln -sfn "$installed_bin" "$link_path"

if [[ -n "$existing_hive" ]] && [[ -n "$existing_canon" ]] && [[ "$existing_canon" != "$link_canon" ]] && [[ "$existing_canon" != "$(readlink -f "$installed_bin" 2>/dev/null || echo "$installed_bin")" ]]; then
  ln -sfn "$installed_bin" "$hv_path"
  warn "existing hive on PATH at ${existing_hive}; installed hv fallback at ${hv_path}"
else
  # Always refresh hv when we already own it so stale symlinks from
  # earlier installs don't dangle.
  if [[ -L "$hv_path" ]]; then
    ln -sfn "$installed_bin" "$hv_path"
  fi
fi

runtime_preflight

log "installed hive ${version} for ${target}"
log "next: run 'hive --version', then 'hive init' in a project"
log "agent skills are installed separately; see install.md"
