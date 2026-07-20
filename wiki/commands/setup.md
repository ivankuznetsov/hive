---
title: hive setup
type: command
source: lib/hive/commands/setup.rb, lib/hive/setup/diagnostics.rb, lib/hive/web/app_bundle.rb, lib/hive/commands/{daemon,web}/service_installer.rb
created: 2026-06-30
updated: 2026-07-20
tags: [command, setup, install, web, daemon]
---

**TLDR**: `hive setup` is the normal native Linux/macOS first run. It diagnoses the workstation, bootstraps authenticated Hive-owned dependencies, installs the daemon, optionally enrolls the current project, and by default installs, enables, starts, and probes the loopback Hive web service. Human and `hive-setup.v1` output report the effective URL and distinct service state.

## Surface

`hive setup [--json] [--service|--no-service] [--no-bootstrap] [--no-init]`

`arch-review-local-web-install` removed the previously advertised `--yes`
flag. Setup has no interactive prompts or confirmation path, so there are no
non-interactive defaults for that flag to accept.

The diagnostic phase checks Ruby 3.4, git, tmux, `gh`, Claude, Codex, Node/npm, QMD, the managed web bundle, and SQLite through `Hive::Setup::Diagnostics`. Missing QMD and missing/stale managed web bundles are bootstrappable; hard failures still make the command fail even when all provisioning phases succeed.

Without `--no-bootstrap`, setup provisions in this order:

1. Install QMD through `npm install --global --prefix <data_home>/qmd @tobilu/qmd` when diagnostics report it missing and npm is available. Failed npm stderr is captured in the `qmd` phase `message`.
2. Install or refresh the managed Rails web bundle through `Hive::Web::AppBundle.ensure!`.
3. Run `hive daemon install` semantics through `Hive::Commands::Daemon::ServiceInstaller` with `autostart: true`, `force: true`, and the same `Hive::InvokedBinary.path` that setup was invoked through.
4. Initialize or enroll the current project unless `--no-init` is passed. If `Hive::Commands::Init` reports the project is already initialized, setup falls back to `hive daemon enable <current-project-name>`.
5. Unless `--no-service` is passed, install the separate `hive-web` service through `Hive::Commands::Web::ServiceInstaller`, also using `Hive::InvokedBinary.path`, and observe installed, enabled/loaded, running/active, and bounded readiness state. A failed web-bundle phase blocks this phase rather than starting a broken service.

`--no-service` performs no web-service mutation: it may report a pre-existing
unit read-only but never installs, enables, starts, stops, or disables it.
`--no-bootstrap` is diagnose-only and wins over service flags: it skips
QMD/web-bundle provisioning, daemon service install, project enrollment, and
web service installation. `--no-init` only suppresses project enrollment.
Default configuration remains loopback-only; setup never creates or widens a
LAN/public bind or Tailscale Serve rule. An existing explicitly gated
non-loopback origin is only observed and reported.

## JSON

`--json` emits one `hive-setup.v1` document:

```json
{
  "schema": "hive-setup",
  "schema_version": 1,
  "ok": true,
  "mode": "managed_service",
  "url": "http://127.0.0.1:4567",
  "service": {
    "platform": "linux",
    "unit_path": "/home/user/.config/systemd/user/hive-web.service",
    "service_installed": true,
    "service_enabled": true,
    "service_running": true,
    "service_manager_available": true,
    "url": "http://127.0.0.1:4567",
    "ready": true,
    "readiness": "ready"
  },
  "warnings": [],
  "phases": [
    { "name": "diagnostics", "ok": true },
    { "name": "web_bundle", "ok": true, "path": "/home/user/.local/share/hive/web" },
    { "name": "daemon_service", "ok": true, "outcome": "installed", "target_path": "/home/user/.config/systemd/user/hive-daemon.service", "messages": [] },
    { "name": "enroll", "ok": true, "path": "/home/user/project" },
    { "name": "web_service", "ok": true },
    { "name": "web", "ok": true, "url": "http://127.0.0.1:4567" }
  ]
}
```

`ok` and the process exit code use the same predicate: all recorded phases must
be ok, and diagnostics must have no hard non-bootstrappable failures. Each
provisioning helper runs through the shared `phase(name)` wrapper: the block
returns `[ok, data]`, and any `StandardError` is recorded as an `ok:false`
phase with a `"Class: message"` `message` instead of aborting before the JSON
envelope can be emitted. This covers QMD bootstrap, web-bundle refresh, daemon
service install, enrollment, and optional web-service install through the same
failure shape.

If Thor rejects argv before `Hive::Commands::Setup` runs (for example
`hive setup extra --json`), `bin/hive` still emits the versioned
`hive-setup.v1` `ok:false` usage payload on stdout and exits 64 before the
human `hive:` stderr line. Invalid-byte errors use the same command-family
schema rather than a separate pre-dispatch contract.

## Web Bundle

The managed web app lives under `Hive::Paths.web_app_home` and is version-stamped with `.hive-web-version`. `Hive::Web::AppBundle.ensure!` refreshes when the bundle is missing or when the stamp differs from `Hive::VERSION`; this keeps a CLI upgrade from continuing to serve an old Rails app. `HIVE_WEB_APP_DIR` is the canonical operator-managed override. The deprecated `HIVEBOX_WEB_APP_DIR` alias still works through the next major release and emits migration guidance.

Bundle download defaults to the versioned GitHub Release asset `hive-web-<version>.tar.gz`. Before extraction, setup cosign-verifies the release `SHA256SUMS` identity and then checks the archive's exact manifest digest. A custom remote `HIVE_WEB_BUNDLE_URL` requires an exact `HIVE_WEB_BUNDLE_SHA256`; a local directory is the explicit development/test input. Remote fetches are bounded (`open_timeout: 30`, `read_timeout: 120`). Extraction rejects path traversal and link members, strips setuid/setgid/sticky mode bits from files, accepts nested release archives that contain one Rails app directory, and runs `bundle install` against the staged directory using the installed `hive-cli` package root and package `GEM_HOME`/`GEM_PATH`. A bundler failure leaves the previous working app untouched; an unstamped partial install reads as stale and is re-provisioned on the next `ensure!`.

## Service Installers

Setup installs both managed services with the invoked user-facing binary, so daemon and web units point at the same `hive`/`hv` wrapper. The shared `ServiceInstaller::Base#render_launchd_from` renders macOS plists for both daemon and web services: it substitutes the resolved binary into ProgramArguments, PATH/HIVE_BIN, log paths, and the web plist's bare WorkingDirectory (`/Users/YOU` -> real home). `Daemon::ServiceInstaller#installed_launchd_exec_binary` parses the shell-wrapped ProgramArguments positionally and returns the `$0` slot, so renamed binaries or `hv` wrappers do not become false `unparseable` drift.

The web service is separate from the daemon. `hive web install` writes `~/.config/systemd/user/hive-web.service` on Linux or `~/Library/LaunchAgents/local.hive-web.plist` on macOS; unsupported platforms report a platform exception instead of constructing invalid service-manager argv. Ordinary setup preserves a drifted user-customized unit and points to explicit `hive web install --force` repair. Shared installers expose read-only enabled/running probes; Hive web adds bounded `/health` readiness. Windows has no separate native service manager in this contract: use WSL with systemd or Hivebox.

## Backlinks

- [[cli]]
- [[commands]]
- [[commands/daemon]]
- [[commands/web]]
- [[operating]]
