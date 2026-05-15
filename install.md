# Hive Agent Installer Prompt

You are installing the `hive` CLI for the user. Treat this prompt as the source of truth and run only the commands needed for this host.

## Goal

Install the latest stable Hive release, verify `hive --version`, offer to run `hive init` in the current project, and report any missing runtime dependencies. Do not auto-install runtime dependencies such as `git`, `gh`, `jq`, or agent CLIs.

## Detect

Run:

```bash
uname -s
uname -m
test -f /etc/os-release && cat /etc/os-release || true
command -v hive || true
hive --version || true
```

If `hive --version` already succeeds, report the installed version and skip reinstall unless the user asked for an upgrade.

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
  yay -S hive-bin
elif command -v paru >/dev/null 2>&1; then
  paru -S hive-bin
else
  echo "Install yay or paru first, then run: yay -S hive-bin"
  exit 69
fi
```

Ubuntu 22.04+ / glibc Linux fallback:

```bash
curl -fsSL https://raw.githubusercontent.com/ivankuznetsov/hive/main/install.sh | bash
```

Inspection-friendly bash path:

```bash
curl -fsSL https://raw.githubusercontent.com/ivankuznetsov/hive/main/install.sh -o /tmp/hive-install.sh
bash /tmp/hive-install.sh --dry-run
bash /tmp/hive-install.sh
```

## Verify

Run:

```bash
hive --version || hv --version
hive doctor || true
```

If `hive` is shadowed by Apache Hive, try `hv --version` and tell the user to use `hv` or adjust PATH.

## Initialize Project

If the current directory is a git project and the user wants Hive enabled here, ask before running:

```bash
hive init .
```

During `hive init`, keep the user's prompt choices. If this is non-interactive, Hive uses recommended defaults and writes the daemon service unit without starting it.

## Optional Skills

The Hive skills package is distributed separately through each agent marketplace and may still be unpublished for v0.1.0. If available, offer the matching command:

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
