---
title: hive setup
type: command
source: lib/hive/commands/setup.rb, lib/hive/setup/diagnostics.rb, lib/hive/web/app_bundle.rb, lib/hive/commands/{daemon,web}/service_installer.rb
created: 2026-06-30
updated: 2026-06-30
tags: [command, setup, install, web, daemon]
---

**TLDR**: `hive setup` is the local, non-Docker provisioning command for a workstation install. It runs diagnostics, bootstraps Hive-owned local dependencies it can manage, installs the daemon service, optionally enrolls the current project, optionally installs the web service, and reports the whole run as a `hive-setup` phase list.

## Surface

`hive setup [--json] [--yes] [--service] [--no-bootstrap] [--no-init]`

The diagnostic phase checks Ruby 3.4, git, tmux, `gh`, Claude, Codex, Node/npm, QMD, the managed web bundle, and SQLite through `Hive::Setup::Diagnostics`. Missing QMD and missing/stale managed web bundles are bootstrappable; hard failures still make the command fail even when all provisioning phases succeed.

Without `--no-bootstrap`, setup provisions in this order:

1. Install QMD through `npm install --global --prefix <data_home>/qmd @tobilu/qmd` when diagnostics report it missing and npm is available. Failed npm stderr is captured in the `qmd` phase `message`.
2. Install or refresh the managed Rails web bundle through `Hive::Web::AppBundle.ensure!`.
3. Run `hive daemon install` semantics through `Hive::Commands::Daemon::ServiceInstaller` with `autostart: true`, `force: true`, and the same `Hive::InvokedBinary.path` that setup was invoked through.
4. Initialize or enroll the current project unless `--no-init` is passed. If `Hive::Commands::Init` reports the project is already initialized, setup falls back to `hive daemon enable <current-project-name>`.
5. With `--service`, install the separate `hive-web` service through `Hive::Commands::Web::ServiceInstaller`, also using `Hive::InvokedBinary.path`.

`--no-bootstrap` is diagnose-only: it skips QMD/web-bundle provisioning, daemon service install, project enrollment, and web service install. It still appends the informational `web` phase with the configured `http://<bind>:<port>` URL.

## JSON

`--json` emits a single unversioned document:

```json
{
  "schema": "hive-setup",
  "ok": true,
  "phases": [
    { "name": "diagnostics", "ok": true },
    { "name": "web_bundle", "ok": true, "path": "/home/user/.local/share/hive/web" },
    { "name": "daemon_service", "ok": true, "outcome": "installed", "target_path": "/home/user/.config/systemd/user/hive-daemon.service", "messages": [] },
    { "name": "enroll", "ok": true, "path": "/home/user/project" },
    { "name": "web", "ok": true, "url": "http://127.0.0.1:4567" }
  ]
}
```

`ok` and the process exit code use the same predicate: all recorded phases must be ok, and diagnostics must have no hard non-bootstrappable failures. Setup rescues provisioning exceptions from the web bundle, daemon installer, enrollment, and web-service installer into `ok:false` phase entries with a `message` instead of aborting before the JSON envelope can be emitted.

## Web Bundle

The managed web app lives under `Hive::Paths.web_app_home` and is version-stamped with `.hive-web-version`. `Hive::Web::AppBundle.ensure!` refreshes when the bundle is missing or when the stamp differs from `Hive::VERSION`; this keeps a CLI upgrade from continuing to serve an old Rails app. `HIVEBOX_WEB_APP_DIR` remains an operator-managed override for `hive web` and is not overwritten by setup.

Bundle download defaults to the versioned GitHub Release asset `hive-web-<version>.tar.gz`, or `HIVE_WEB_BUNDLE_URL` when set. Directory URLs are copied for local/testing installs. Remote fetches are bounded (`open_timeout: 30`, `read_timeout: 120`). Extraction rejects path traversal and link members, strips setuid/setgid/sticky mode bits from files, accepts nested release archives that contain one Rails app directory, runs `bundle install` against the staged temp directory before swapping it into place, then writes the version stamp last. A bundler failure leaves the previous working app untouched; an unstamped partial install reads as stale and is re-provisioned on the next `ensure!`.

## Service Installers

Setup installs both managed services with the invoked user-facing binary, so daemon and web units point at the same `hive`/`hv` wrapper. The shared `ServiceInstaller::Base#render_launchd_from` renders macOS plists for both daemon and web services: it substitutes the resolved binary into ProgramArguments, PATH/HIVE_BIN, log paths, and the web plist's bare WorkingDirectory (`/Users/YOU` -> real home). `Daemon::ServiceInstaller#installed_launchd_exec_binary` parses the shell-wrapped ProgramArguments positionally and returns the `$0` slot, so renamed binaries or `hv` wrappers do not become false `unparseable` drift.

The web service is separate from the daemon. `hive web install` writes `~/.config/systemd/user/hive-web.service` on Linux or `~/Library/LaunchAgents/local.hive-web.plist` on macOS; unsupported platforms raise instead of constructing invalid service-manager argv. `hive web start --detach` reloads systemd-user before starting so a unit written while systemd-user was previously unavailable becomes visible.

## Backlinks

- [[cli]]
- [[commands]]
- [[commands/daemon]]
- [[commands/web]]
- [[operating]]
