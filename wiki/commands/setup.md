---
title: hive setup
type: command
source: lib/hive/commands/setup.rb, lib/hive/commands/setup_agents.rb, lib/hive/setup/diagnostics.rb, lib/hive/web/app_bundle.rb, lib/hive/commands/{daemon,web}/service_installer.rb
created: 2026-06-30
updated: 2026-07-26
tags: [command, setup, install, agents, skills, consent, web, daemon]
---

**TLDR**: `hive setup` is the normal native Linux/macOS first run. It checks
dependencies, provisions Hive's operating skill for Claude, Codex, and Pi
before other mutations, bootstraps authenticated Hive-owned dependencies,
installs the daemon, optionally enrolls the current project, and by default
installs, enables, starts, and probes the loopback Hive web service. One
preview/consent boundary covers the run: interactive setup asks once; JSON or
non-TTY setup requires `--yes` and otherwise performs no mutation. Human and
`hive-setup.v1` output report the effective URL and distinct service state.

## Surface

`hive setup [--json] [--service|--no-service] [--no-bootstrap] [--no-init] [--yes]`

`--yes` accepts the revalidated plan for unattended operation. It does not
bypass conflicts or let Hive replace user-owned agent skills. Without
`--yes`, a TTY receives the normal `hive setup-agents` aggregate preview and
one confirmation prompt. JSON never prompts. A JSON or non-TTY run without
`--yes` records `classification: consent_required`, exits non-zero, and stops
before diagnostics, native agent discovery, QMD, web-bundle, service, or
project mutation. Its diagnostics phase is explicitly marked `skipped: true`
with reason `consent_required`.

On consented runs and explicit `--no-bootstrap` diagnosis, the diagnostic phase
checks Ruby 3.4, git, tmux, `gh`, Claude, Codex, Node/npm, QMD, the managed web
bundle, and SQLite through `Hive::Setup::Diagnostics`. Missing QMD and
missing/stale managed web bundles are bootstrappable; hard failures still make
the command fail even when all provisioning phases succeed.

Without `--no-bootstrap`, setup provisions in this order:

1. Inspect and provision the bundled Hive operating skill plus other selected
   managed capabilities through `Hive::Commands::SetupAgents`. The nested
   `hive init` later in the run suppresses its own agent-skill preflight, so
   setup never asks twice.
2. Install QMD through `npm install --global --prefix <data_home>/qmd
   @tobilu/qmd` when diagnostics report it missing and npm is available.
   Diagnostics run the discovered QMD's bounded `--version` probe rather than
   trusting its executable bit. A broken Hive-managed QMD is bootstrappable;
   a broken operator-owned QMD earlier on `PATH` is a hard diagnostic failure
   with repair guidance because installing another binary would leave the
   broken one active. After npm succeeds, setup also requires the managed
   executable to exist and pass a 10-second `--version` probe; timeout
   terminates the probe process group. Failed npm or startup detail is
   secret-redacted, control-safe, bounded, and captured in the `qmd` phase
   `message`.
3. Install or refresh the managed Rails web bundle through
   `Hive::Web::AppBundle.ensure!`.
4. Run `hive daemon install` semantics through
   `Hive::Commands::Daemon::ServiceInstaller` with autostart, forced template
   refresh, and the same `Hive::InvokedBinary.path` used to invoke setup. The
   adapter delegates platform-neutral service planning/application to
   `Hive::UserService`.
5. Initialize or enroll the current project unless `--no-init` is passed. If
   the project is already initialized, setup enables it for daemon dispatch.
6. Unless `--no-service` is passed, install the separate `hive-web` service
   through the same boundary and invoked binary, then observe installed, enabled/loaded,
   running/active, and bounded readiness state. A failed web-bundle phase
   blocks mutation but still reports the read-only lifecycle state. If a
   refreshed bundle replaces an app already held by a running service, setup
   restarts that service before probing readiness.

`--no-service` performs no web-service mutation: it may report a pre-existing
unit read-only but never installs, enables, starts, stops, or disables it.
`--no-bootstrap` is diagnose-only and wins over service flags: it skips agent
skills, QMD/web-bundle provisioning, daemon/web service installation, and
project enrollment. It still appends the informational `web` phase with the
configured URL. `--no-init` only suppresses project enrollment. Default
configuration remains loopback-only; setup never creates or widens a
LAN/public bind or Tailscale Serve rule. An existing explicitly gated
non-loopback origin is only observed and reported.

## JSON

`--json` emits one `hive-setup.v1` document. The `agent_skills` phase contains
the same structured consent, operation, and health evidence as setup-agents:

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
    {
      "name": "agent_skills",
      "ok": true,
      "classification": "success",
      "consent": {"granted": true, "provenance": "yes_flag"},
      "targets": [],
      "operation_results": [],
      "final_health": [],
      "setup_agents_exit_code": 0
    },
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
envelope can be emitted. This covers agent skills, QMD bootstrap, web-bundle
refresh, daemon service install, enrollment, and optional web-service install
through the same failure shape. An unavailable agent is a non-blocking skip;
an actionable conflict, failed operation, or residual unhealthy available
target fails the phase.

If Thor rejects argv before `Hive::Commands::Setup` runs (for example
`hive setup extra --json`), `bin/hive` still emits the versioned
`hive-setup.v1` `ok:false` usage payload on stdout and exits 64 before the
human `hive:` stderr line. Invalid-byte errors use the same command-family
schema rather than a separate pre-dispatch contract. These pre-dispatch errors
also carry `mode`, effective `url`, migration `warnings`, and the observed
service lifecycle so automation does not lose semantic context on failures.

## Web Bundle

The managed web app lives under `Hive::Paths.web_app_home` and is version-stamped with `.hive-web-version`. `Hive::Web::AppBundle.ensure!` refreshes when the bundle is missing, when the stamp differs from `Hive::VERSION`, or when the compiled asset manifest is missing/broken; this keeps a CLI upgrade from continuing to serve an old or assetless Rails app. `HIVE_WEB_APP_DIR` is the canonical operator-managed override. The deprecated `HIVEBOX_WEB_APP_DIR` alias still works through the next major release and emits migration guidance.

Bundle download defaults to the versioned GitHub Release asset `hive-web-<version>.tar.gz`. Before extraction, setup cosign-verifies that the release `SHA256SUMS` certificate came from `.github/workflows/release.yml` at the exact expected `v<version>` tag with a bounded verifier process, then checks the archive's exact manifest digest. A custom remote `HIVE_WEB_BUNDLE_URL` requires an exact `HIVE_WEB_BUNDLE_SHA256`; a local directory is the explicit development/test input. Remote fetches are bounded (`open_timeout: 30`, `read_timeout: 120`). Extraction rejects path traversal and link members, strips setuid/setgid/sticky mode bits from files, and accepts nested release archives that contain one Rails app directory. It installs dependencies beneath the user's writable data home, precompiles production assets, validates every manifest target, and only then atomically activates and stamps the staged app. Preparation failure leaves the previous working app untouched.

## Service Installers

Setup installs both managed services with the invoked user-facing binary, so daemon and web units point at the same `hive`/`hv` wrapper. The shared `ServiceInstaller::Base#render_launchd_from` renders macOS plists for both daemon and web services: it substitutes the resolved binary into ProgramArguments, PATH/HIVE_BIN, log paths, and the web plist's bare WorkingDirectory (`/Users/YOU` -> real home). `Daemon::ServiceInstaller#installed_launchd_exec_binary` parses the shell-wrapped ProgramArguments positionally and returns the `$0` slot, so renamed binaries or `hv` wrappers do not become false `unparseable` drift.

The web service is separate from the daemon. `hive web install` writes `~/.config/systemd/user/hive-web.service` on Linux or `~/Library/LaunchAgents/local.hive-web.plist` on macOS and pins all six resolved `HIVE_WEB_*` values into the unit; unsupported platforms report a platform exception instead of constructing invalid service-manager argv. When setup receives the installer's successful `unsupported` outcome (including Linux without systemd-user), its service fields remain observationally exact (`enabled`, `running`, and `ready` stay false with `readiness: manager_unavailable`), but the platform-exception phases and process exit remain successful and report foreground `hive web`, WSL-systemd, and Hivebox recovery paths. A genuine install failure, drifted unit, or active-but-not-ready service remains nonzero. Ordinary setup preserves a drifted user-customized unit and points to explicit `hive web install --force` repair. Repeated macOS setup skips `launchctl load` when an unchanged plist is already loaded. Shared installers expose read-only enabled/running probes; mutating setup/install resamples asynchronous launchd lifecycle state before Hive web probes the manager-owned local bind for bounded `/health` readiness, while read-only status stays immediate and reports the separately advertised effective origin. Windows has no separate native service manager in this contract: use WSL with systemd or Hivebox.

The mutating web-install readiness window uses 40 samples at 250 ms intervals,
so a cold packaged Rails boot can take roughly ten seconds without producing a
false `active_not_ready` install failure. This longer window does not make
`hive web status` block; status retains its single immediate health sample.

## Backlinks

- [[cli]]
- [[commands]]
- [[commands/daemon]]
- [[commands/web]]
- [[operating]]
