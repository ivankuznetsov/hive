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
      command -v ldd >/dev/null 2>&1 || die "ldd not found; refusing to install — Alpine/musl/distroless is tier-3"
      if ldd --version 2>&1 | grep -qi musl; then
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
  local api body tag
  api="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest"
  body="$(curl -fsSL "$api")" || die "could not fetch latest release; set HIVE_VERSION=vX.Y.Z to skip the API call"
  tag="$(printf '%s\n' "$body" | jq -r '.tag_name // empty')"
  [[ -n "$tag" && "$tag" != "null" ]] || die "could not parse tag_name from latest release; set HIVE_VERSION=vX.Y.Z"
  printf '%s\n' "$tag"
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

runtime_preflight() {
  local dep missing=0
  for dep in curl git bash claude gh jq; do
    if ! command -v "$dep" >/dev/null 2>&1; then
      warn "missing runtime dependency '${dep}' ($(install_hint "$dep"))"
      missing=1
    fi
  done
  if [[ "$missing" -ne 0 ]]; then
    die "install incomplete: required dependencies missing"
  fi
}

target="$(detect_target)"
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

curl -fsSL "$archive_url" -o "${tmpdir}/${archive_name}"
curl -fsSL "$checksums_url" -o "${tmpdir}/SHA256SUMS"

# Cosign verify SHA256SUMS when both the signature blob and the
# keyless cert are published — release.yml writes both. We skip the
# verification only when cosign isn't installed; missing signature
# files are an attestable regression and we fail closed.
if command -v cosign >/dev/null 2>&1; then
  curl -fsSL "$sig_url" -o "${tmpdir}/SHA256SUMS.sig" \
    || die "could not fetch SHA256SUMS.sig for ${version}; refusing unsigned install"
  curl -fsSL "$cert_url" -o "${tmpdir}/SHA256SUMS.pem" \
    || die "could not fetch SHA256SUMS.pem for ${version}; refusing unsigned install"
  cosign verify-blob \
    --certificate "${tmpdir}/SHA256SUMS.pem" \
    --signature "${tmpdir}/SHA256SUMS.sig" \
    --certificate-identity-regexp ".*" \
    --certificate-oidc-issuer-regexp ".*" \
    "${tmpdir}/SHA256SUMS" \
    || die "cosign verify-blob failed for SHA256SUMS"
else
  warn "cosign not installed; skipping signature verification (still validating SHA256)"
fi

# Strict line match: optional `./` prefix, sha digest, two-space sep,
# exact archive_name, optional CR. Avoids picking up adjacent rows
# that just contain archive_name as a substring.
expected_line="$(grep -E "^[a-f0-9]{64}  (\./)?${archive_name}[[:space:]]*$" "${tmpdir}/SHA256SUMS")"
[[ -n "$expected_line" ]] || die "SHA256SUMS does not contain ${archive_name}"

actual="$($(sha256_cmd) "${tmpdir}/${archive_name}" | awk '{print $1}')"
expected="$(printf '%s\n' "$expected_line" | awk '{print $1}')"
[[ "$actual" == "$expected" ]] || die "checksum mismatch for ${archive_name}"

mkdir -p "$install_dir" "$bin_home" "$data_home"
tar -xzf "${tmpdir}/${archive_name}" -C "$tmpdir"
extracted="${tmpdir}/hive-${version#v}-${target}"
[[ -x "${extracted}/bin/hive" ]] || die "release archive does not contain executable bin/hive"

rm -rf "$install_dir"
mkdir -p "$(dirname "$install_dir")"
mv "$extracted" "$install_dir"

if [[ "$(uname -s)" == "Darwin" ]] && command -v xattr >/dev/null 2>&1; then
  # Surface xattr failures to stderr so the user can see when Gatekeeper
  # quarantine removal silently fails. Treat "attribute not present"
  # (exit 1 on macOS) as benign by falling back to true.
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
# `dev` during the brief gap.
printf 'bash\n' > "${data_home}/install-channel"
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
