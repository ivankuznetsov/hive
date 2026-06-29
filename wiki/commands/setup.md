---
title: hive setup
type: command
source: lib/hive/commands/setup.rb, lib/hive/setup/diagnostics.rb, lib/hive/commands/daemon/service_installer.rb, lib/hive/commands/web/service_installer.rb
created: 2026-06-29
updated: 2026-06-29
tags: [command, setup, install, web, daemon]
---

**TLDR**: `hive setup` is the local, non-Docker first-run path for Hive web mode. It runs setup diagnostics, bootstraps Hive-owned pieces it can manage (`qmd` and the managed Rails web bundle unless `--no-bootstrap` is set), force-repairs the daemon service to the current invoked Hive binary, initializes or daemon-enrolls the current project unless `--no-init` is set, optionally installs the managed web service with `--service`, and prints the `hive web` URL. `--json` emits an unversioned `hive-setup` phase report; hard prerequisite failures make the command exit 1 after printing the report.

## Usage

```
hive setup [--json] [--yes] [--service] [--no-bootstrap] [--no-init]
```

`--yes` is currently a non-interactive-defaults flag reserved by the command initializer; the committed implementation does not prompt. `--service` also installs/starts the web service; without it, setup still installs the daemon service and leaves the web UI available through foreground `hive web`. `--no-bootstrap` leaves managed QMD/web-bundle bootstrap work out of the run. `--no-init` skips project initialization/enrollment, which is useful on a host-level setup pass outside a project checkout.

## Diagnostics

`Hive::Setup::Diagnostics` checks Ruby, git, tmux, `gh`, Claude, Codex, Node, npm, QMD, the managed web bundle, and the sqlite3 binary. Result statuses are a closed set: `ok`, `missing`, `version_too_old`, and `unauthenticated`. The aggregate is successful when every row is either `ok` or `bootstrappable`; bootstrappable rows are setup-managed missing/stale pieces such as QMD and the managed web bundle.

Agent authentication accepts API-key env vars plus the CLI-owned on-disk login artifacts reported by `Hive::AgentProfiles.logged_in?`. `CODEX_HOME` is deliberately not treated as an auth signal because it can point at an empty config directory. A current web bundle is a normal `ok` row with `bootstrappable: false`; a stale bundle is `version_too_old` but bootstrappable, and a `LoadError` while loading bundle support is a non-bootstrappable missing row so setup does not claim a reinstall can fix a code-load problem.

Version parsing uses the shared numeric pattern `\d+(?:\.\d+)+`, matching the daemon binary-drift version probe in [[commands/daemon]].

## Phases

The command records a phase list in order:

| Phase | Behavior |
|-------|----------|
| `diagnostics` | Runs the checks above and records their JSON form. |
| `qmd` | When QMD is missing and bootstrappable, runs `npm install --global --prefix <data_home>/qmd @tobilu/qmd`. Skipped under `--no-bootstrap`. |
| `web_bundle` | Calls `Hive::Web::AppBundle.ensure!`. Skipped under `--no-bootstrap`; failures become a failed phase instead of aborting the rest of setup. |
| `daemon_service` | Installs the daemon service with `force: true` and `binary_path: Hive::InvokedBinary.path`, so local setup repairs the service unit to the same user-facing wrapper that invoked setup. |
| `enroll` | Runs `hive init . --force` for a new project, or enables the already-registered current project through `hive daemon enable <name>`. Skipped under `--no-init`. |
| `web_service` | Only with `--service`, installs the managed web service. |
| `web` | Reports the URL from `Config.load_global_web` (`http://<bind>:<port>`). |

## JSON

`--json` prints one document:

```json
{
  "schema": "hive-setup",
  "ok": true,
  "phases": [
    {"name": "diagnostics", "ok": true, "results": []},
    {"name": "daemon_service", "ok": true, "outcome": "installed", "target_path": "...", "messages": []},
    {"name": "web", "ok": true, "url": "http://127.0.0.1:4567"}
  ]
}
```

The schema is currently unversioned and not registered under `Hive::Schemas::SCHEMA_VERSIONS`. Text mode prints each phase as `hive setup: <phase> ok|needs attention`, then prints `fix <name>: <command>` lines for non-bootstrappable diagnostic failures with a repair command.

## Tests

- `test/unit/setup/diagnostics_test.rb` pins diagnostic row shape, missing vs unauthenticated `gh`, version-too-old classification, QMD bootstrappability, and aggregate JSON shape.
- `test/unit/agent_profiles_test.rb` covers the on-disk login artifact predicate that setup diagnostics now reuses for Claude/Codex auth detection.

## Backlinks

- [[cli]] · [[commands]] · [[commands/daemon]] · [[commands/web]]
- [[modules/agent_profile]]
- [[operating]]
