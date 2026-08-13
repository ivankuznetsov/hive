# Hive Agent Installer Prompt

You are installing the `hive` CLI for the user. Treat this prompt as the source of truth and run only the commands needed for this host.

## Goal

Install the latest stable Hive release, install or repair the QMD wiki indexer,
verify `hive --version`, run the normal native `hive setup`, offer project
initialization, and report the truthful daemon, babysitter, and Hive web service state. Do
not auto-install runtime dependencies such as `git`, `gh`, agent CLIs, or
Node.js/npm; QMD is the exception once npm is already available because Hive's
managed wiki refresh scripts use it. The bash installer requires Ruby 3.4,
`curl`, `jq`, `cosign`, and a checksum tool. Hive ships as a rubygem
(`hive-cli`) plus an authenticated managed web bundle; all three native
channels use the same release artifacts. Default setup is loopback-only and
never creates LAN/public or Tailscale exposure.

## Detect

Run:

```bash
uname -s
uname -m
test -f /etc/os-release && cat /etc/os-release || true
command -v hive || true
command -v qmd || true
hive --version 2>/dev/null | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' && echo "hive installed" || echo "hive not installed"
qmd --version 2>/dev/null || true
```

`bin/hive --version` prints a bare `X.Y.Z` line (no `hive ` prefix). Apache Hive's `hive --version` first line starts with a capital-H `Hive X.Y.Z`, so a strict `^[0-9]+\.[0-9]+\.[0-9]+$` regex distinguishes the two. If the strict match SUCCEEDS, the host already has the Hive CLI: SKIP the Install Commands block below and go straight to Verify / Initialize Project. To upgrade an existing Hive install, run `hive update` instead of reinstalling. If the strict match fails, continue with the Install Commands below.

## Choose Channel

Use this decision tree:

- macOS arm64: prefer Homebrew.
- Arch Linux: prefer AUR through `yay` or `paru`.
- Ubuntu 22.04+ or other glibc Linux on x86_64/aarch64: use the bash installer.
- Windows: use WSL with systemd enabled for the native path, or offer Hivebox.
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
# Release maintainers: bump v0.7.1 in both installer URLs when cutting a new stable release.
curl -fsSL https://raw.githubusercontent.com/ivankuznetsov/hive/v0.7.1/install.sh -o "$tmpdir/hive-install.sh"
bash "$tmpdir/hive-install.sh"
```

To inspect the installer first, run a dry-run before the real invocation. State from `--dry-run` is not shared with the real run:

```bash
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
# Release maintainers: bump v0.7.1 in both installer URLs when cutting a new stable release.
curl -fsSL https://raw.githubusercontent.com/ivankuznetsov/hive/v0.7.1/install.sh -o "$tmpdir/hive-install.sh"
bash "$tmpdir/hive-install.sh" --dry-run
bash "$tmpdir/hive-install.sh"
```

## Install / Repair QMD

The bash installer installs QMD automatically when npm is available. For Homebrew/AUR installs, or when `qmd --version` fails with a native module / `NODE_MODULE_VERSION` error, install or repair Hive's managed QMD copy:

```bash
if command -v npm >/dev/null 2>&1; then
  (
    set -euo pipefail
    qmd_parent="${XDG_DATA_HOME:-$HOME/.local/share}/hive"
    qmd_prefix="$qmd_parent/qmd"
    qmd_bin_home="${XDG_BIN_HOME:-$HOME/.local/bin}"
    qmd_package="@tobilu/qmd@2.5.3"
    qmd_integrity="sha512-wUKc4pSPDbgs7mV7JYE8/Qj1pNXXatJFV8byTT/T3yLaoAXheFtWu0BgSWwoWGhRkMmxl5Qyitt66NHgbMyeBA=="
    mkdir -p "$qmd_parent" "$qmd_bin_home"
    qmd_stage="$(mktemp -d "$qmd_parent/.qmd-stage.XXXXXX")"
    qmd_download="$(mktemp -d)"
    qmd_backup=""
    cleanup_qmd_repair() {
      rm -rf "$qmd_download" "$qmd_stage"
      if [[ -n "$qmd_backup" && -e "$qmd_backup" && ! -e "$qmd_prefix" ]]; then
        mv "$qmd_backup" "$qmd_prefix"
      fi
    }
    trap cleanup_qmd_repair EXIT

    pack_json="$(npm pack "$qmd_package" --json --pack-destination "$qmd_download")"
    qmd_tarball="$(printf '%s' "$pack_json" | ruby -rjson -e '
      filename = JSON.parse(STDIN.read).fetch(0).fetch("filename")
      abort "unsafe npm pack filename" unless File.basename(filename) == filename && filename.end_with?(".tgz")
      print File.join(ARGV.fetch(0), filename)
    ' "$qmd_download")"
    actual_integrity="$(ruby -rdigest -rbase64 -e '
      digest = Digest::SHA512.file(ARGV.fetch(0)).digest
      print "sha512-", Base64.strict_encode64(digest)
    ' "$qmd_tarball")"
    [[ "$actual_integrity" == "$qmd_integrity" ]]

    npm install --global --prefix "$qmd_stage" --no-audit --no-fund "$qmd_tarball"
    npm rebuild --global --prefix "$qmd_stage" better-sqlite3
    "$qmd_stage/bin/qmd" --version
    node -e '
      const { createRequire } = require("node:module");
      const qmdRequire = createRequire(process.argv[1]);
      const Database = qmdRequire("better-sqlite3");
      const db = new Database(":memory:");
      db.prepare("SELECT 1").get();
      db.close();
    ' "$qmd_stage/lib/node_modules/@tobilu/qmd/package.json"

    qmd_backup="$(mktemp -d "$qmd_parent/.qmd-backup.XXXXXX")"
    rmdir "$qmd_backup"
    [[ ! -e "$qmd_prefix" ]] || mv "$qmd_prefix" "$qmd_backup"
    mv "$qmd_stage" "$qmd_prefix"
    qmd_stage=""
    rm -rf "$qmd_backup"
    qmd_backup=""
    qmd_link="$qmd_bin_home/qmd"
    managed_qmd="$(ruby -e 'print File.realpath(ARGV.fetch(0))' "$qmd_prefix/bin/qmd")"
    if [[ ! -e "$qmd_link" && ! -L "$qmd_link" ]]; then
      ln -s "$qmd_prefix/bin/qmd" "$qmd_link"
    elif [[ -L "$qmd_link" ]] && \
      [[ "$(ruby -e 'begin; print File.realpath(ARGV.fetch(0)); rescue SystemCallError; end' "$qmd_link")" == "$managed_qmd" ]]; then
      ln -sfn "$qmd_prefix/bin/qmd" "$qmd_link"
    else
      printf 'existing qmd at %s; leaving it unchanged\n' "$qmd_link" >&2
    fi
    "$qmd_prefix/bin/qmd" --version
  )
else
  echo "qmd install skipped: npm is missing; install Node.js/npm and rerun this section" >&2
fi
```

`HIVE_QMD_BIN` is a runtime override pointing at an executable `qmd` (read by the generated wiki scripts and `hive doctor` when PATH or the managed install path is not enough). The bash installer pins QMD to `@tobilu/qmd@2.5.3`, downloads that exact tarball once, and verifies its sha512 integrity locally before install. `HIVE_QMD_NPM_PACKAGE` may select only another exact `@tobilu/qmd@X.Y.Z` version and then requires the matching `HIVE_QMD_NPM_INTEGRITY`; arbitrary package names, URLs, tags, and ranges are rejected before npm runs. Optional npm and Node operations time out after `HIVE_QMD_TIMEOUT_SECONDS` (default 600 seconds).

Do not install Node.js/npm automatically. If npm is missing, report that Hive core is installed but QMD-backed wiki search needs Node.js/npm.

## Verify

Run:

```bash
if hive --version 2>/dev/null | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  hive_cmd=hive
elif hv --version 2>/dev/null | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  hive_cmd=hv
else
  echo "verify failed: expected Hive CLI version X.Y.Z from hive or hv" >&2
  exit 1
fi
"$hive_cmd" --version
```

If `hive` is shadowed by Apache Hive, try `hv --version` and tell the user to use `hv` or adjust PATH.

## Native Setup

After version verification, run the shared setup command and parse its
versioned envelope:

```bash
"$hive_cmd" setup --no-init --yes --json
```

On supported Linux/macOS this bootstraps the authenticated managed Rails
bundle, installs/enables/starts the daemon, PR babysitter, and Hive web services, optionally
enrolls the current project only after separate explicit consent, probes bounded readiness, and reports the effective
URL. Report `service_installed`, `service_enabled`, `service_running`, `ready`,
and `readiness` separately; never describe the URL as available when `ready` is
false. If a customized web unit is drifted, leave it byte-identical and report
`"$hive_cmd" web install --force` as the explicit repair. If the user opts out,
run `"$hive_cmd" setup --no-service --yes --json`; that performs no web-service
mutation and does not stop or disable an existing unit. Use `--no-bootstrap`
only for a diagnose-only run with no provisioning.

## Local Web Setup

Bare Hive web remains the foreground path:

```bash
"$hive_cmd" web
```

It bootstraps as needed and blocks in the foreground. The untouched setup URL
is `http://127.0.0.1:4567`. On a loopback bind it runs no-auth against the
existing local Hive registry and workflow state; GitHub connection is optional
and does not claim Hivebox ownership. A loopback reverse proxy such as
Tailscale Serve retains that local behavior, so the proxy must authenticate
and restrict its clients; an unrestricted forwarder would expose the local UI.
Set `web.local_loopback: false` to require GitHub login even on loopback. Never
run bare `hive web` as a read-only status check. Use
`"$hive_cmd" web status --json` instead. The normal approved `hive setup`
already installs the managed service unless `--no-service` is passed.

Choose [Hivebox](packaging/docker/README.md) only for container isolation,
multiple local instances, containment of untrusted agents, or reproducible
server/NAS deployment.

## Initialize Project

If the current directory is a git project and the user wants Hive enabled here, ask before running:

```bash
"$hive_cmd" init .
"$hive_cmd" doctor || true
```

During `hive init`, keep the user's prompt choices. The daemon prompt is per-project enrollment (`daemon.enabled`) only; the service autostart has already been installed globally. If init is non-interactive, Hive uses recommended defaults and enrolls the project. `hive doctor` runs AFTER `hive init` because it requires an initialized project root.

## Provision Agent Skills

`hive doctor` is read-only and reports the enabled built-in capabilities for
Claude, Codex, and Pi. If it finds unresolved managed rows, offer Hive's
aggregate, consent-safe setup command instead of hand-installing packages:

```bash
"$hive_cmd" setup-agents
```

The command prints the exact native package commands and Hive-owned files,
prompts once, revalidates, executes independent operations, and verifies the
result. Never answer the consent prompt on the user's behalf. In an explicitly
unattended flow where the user already authorized mutation, use:

```bash
"$hive_cmd" setup-agents --yes --json
```

Hive manages the declared Compound Engineering, llm-wiki, and Claude PR Review
Toolkit packages. It does not install agent CLIs, authenticate providers,
replace custom skills, overwrite a user-owned Codex source, or replace a
user-authored Claude `/plan` command. Report conflicts with the remediation
printed by doctor/setup.

## Final Report

Report:

- channel used
- command run
- Hive CLI version output (`"$hive_cmd" --version`)
- setup mode, effective URL, and distinct daemon/Hive web service state from `"$hive_cmd" setup --no-init --yes --json`
- whether `hive init` was run
- missing runtime dependencies from `hive doctor`
- `qmd --version` output, or the reason QMD install/repair was skipped
- whether managed agent skills were healthy, provisioned with consent, unavailable, or left conflicted
