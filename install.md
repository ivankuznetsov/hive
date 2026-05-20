# Hive Agent Installer Prompt

You are installing the `hive` CLI for the user. Treat this prompt as the source of truth and run only the commands needed for this host.

## Goal

Install the latest stable Hive release, verify `hive --version`, offer to run `hive init` in the current project, and report any missing runtime dependencies. Do not auto-install runtime dependencies such as `git`, `gh`, or agent CLIs; the bash installer reports its own installer prerequisites (`curl`, `jq`, `tar`, checksum tool) when that channel is used.

## Detect

Run:

```bash
uname -s
uname -m
test -f /etc/os-release && cat /etc/os-release || true
command -v hive || true
hive --version 2>/dev/null | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' && echo "hive installed" || echo "hive not installed"
```

`bin/hive --version` prints a bare `X.Y.Z` line (no `hive ` prefix). Apache Hive's `hive --version` first line starts with a capital-H `Hive X.Y.Z`, so a strict `^[0-9]+\.[0-9]+\.[0-9]+$` regex distinguishes the two. If the strict match SUCCEEDS, the host already has the Hive CLI: SKIP the Install Commands block below and go straight to Verify / Initialize Project. To upgrade an existing Hive install, run `hive update` instead of reinstalling. If the strict match fails, continue with the Install Commands below.

## Choose Channel

Use this decision tree:

- macOS arm64: prefer Homebrew.
- Arch Linux: prefer AUR through `yay` or `paru`.
- Ubuntu 22.04+ or other glibc Linux on x86_64/aarch64: use the bash installer.
- Alpine, NixOS, BSD, and musl Linux: stop and report unsupported tier-3 platform.

## Install Commands

macOS arm64:

```bash
brew tap ivankuznetsov/hive
brew install ivankuznetsov/hive/hive
```

Arch Linux:

```bash
if command -v yay >/dev/null 2>&1; then
  yay -S --noconfirm --needed hive-bin
elif command -v paru >/dev/null 2>&1; then
  paru -S --noconfirm --needed hive-bin
else
  # The agent should treat status 69 as "user must install yay or paru first" and abort.
  echo "Install yay or paru first, then run: yay -S hive-bin"
  exit 69
fi
```

Ubuntu 22.04+ / glibc Linux fallback (pin to the current release tag, not `main`). Download the installer to a temporary file, then run it:

```bash
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
# Release maintainers: bump v0.1.0 in both installer URLs when cutting a new stable release.
curl -fsSL https://raw.githubusercontent.com/ivankuznetsov/hive/v0.1.0/install.sh -o "$tmpdir/hive-install.sh"
bash "$tmpdir/hive-install.sh"
```

To inspect the installer first, run a dry-run before the real invocation. State from `--dry-run` is not shared with the real run:

```bash
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
# Release maintainers: bump v0.1.0 in both installer URLs when cutting a new stable release.
curl -fsSL https://raw.githubusercontent.com/ivankuznetsov/hive/v0.1.0/install.sh -o "$tmpdir/hive-install.sh"
bash "$tmpdir/hive-install.sh" --dry-run
bash "$tmpdir/hive-install.sh"
```

## Verify

Run:

```bash
if hive --version 2>/dev/null | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  hive --version
elif hv --version 2>/dev/null | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  hv --version
else
  echo "verify failed: expected Hive CLI version X.Y.Z from hive or hv" >&2
  exit 1
fi
```

If `hive` is shadowed by Apache Hive, try `hv --version` and tell the user to use `hv` or adjust PATH.

## Initialize Project

If the current directory is a git project and the user wants Hive enabled here, ask before running:

```bash
hive init .
hive doctor || true
```

During `hive init`, keep the user's prompt choices. If this is non-interactive, Hive uses recommended defaults and writes the daemon service unit without starting it. `hive doctor` runs AFTER `hive init` because it requires an initialized project root.

## Optional Skills

The Hive skills package is deferred to a v0.1.x follow-up (tracked in `wiki/gaps.md`). DO NOT RUN these commands until that package is published; treat the slugs below as the intended marketplace identifiers. If/when the package is published, offer the matching command:

```bash
claude plugin install ivankuznetsov/hive-skills
codex plugin install ivankuznetsov/hive-skills
pi install ivankuznetsov/hive-skills
```

If the package is unavailable, report: "Hive core installed; skills package coming soon at ivankuznetsov/hive-skills."

## Final Report

Report:

- channel used
- command run
- `hive --version` output
- whether `hive init` was run
- missing runtime dependencies from `hive doctor`
- whether the optional skills package was installed or skipped
