---
title: hive setup
type: command
source: lib/hive/commands/setup.rb, lib/hive/commands/setup_agents.rb, lib/hive/setup/diagnostics.rb, lib/hive/web/app_bundle.rb, lib/hive/commands/{daemon,web}/service_installer.rb
created: 2026-06-30
updated: 2026-07-20
tags: [command, setup, install, agents, skills, consent, web, daemon]
---

**TLDR**: `hive setup` is the local, non-Docker workstation provisioner. It
checks dependencies, provisions Hive's operating skill for Claude, Codex, and
Pi before other mutations, then repairs Hive-owned dependencies, installs the
daemon, enrolls the project, and optionally installs the web service. One
preview/consent boundary covers the run: interactive setup asks once; JSON or
non-TTY setup requires `--yes` and otherwise performs no mutation.

## Surface

`hive setup [--json] [--service] [--no-bootstrap] [--no-init] [--yes]`

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
3. Install or refresh the managed Rails web bundle through
   `Hive::Web::AppBundle.ensure!`.
4. Install the daemon with autostart through the same invoked `hive`/`hv`
   binary.
5. Initialize or enroll the current project unless `--no-init` is passed.
6. With `--service`, install the separate `hive-web` service through the same
   invoked binary.

`--no-bootstrap` is diagnose-only: it skips agent skills, QMD/web-bundle
provisioning, daemon/web service installation, and project enrollment. It
still appends the informational `web` phase with the configured URL.

## JSON

`--json` emits one unversioned document. The `agent_skills` phase contains the
same structured consent, operation, and health evidence as setup-agents:

```json
{
  "schema": "hive-setup",
  "ok": true,
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
`hive setup extra --json`), `bin/hive` emits an unversioned `hive-setup`
`ok:false` usage payload on stdout and exits 64 before the human `hive:` stderr
line.

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
