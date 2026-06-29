---
title: hive setup
type: command
source: lib/hive/commands/setup.rb, lib/hive/setup/diagnostics.rb, lib/hive/web/app_bundle.rb
created: 2026-06-29
updated: 2026-06-29
tags: [command, setup, web, daemon, diagnostics]
---

**TLDR**: `hive setup` provisions the local, non-Docker Hive web mode. It
runs runtime diagnostics, bootstraps Hive-owned local dependencies (QMD and the
managed Rails app under `${XDG_DATA_HOME}/hive/web`), installs the daemon
service, enrolls the current project, and reports the foreground web URL.

## CLI

```bash
hive setup [--json] [--yes] [--service] [--no-bootstrap] [--no-init]
```

- `--json` emits a `hive-setup` envelope with ordered phase results.
- `--service` also installs the separate `hive-web` service.
- `--no-bootstrap` diagnoses only; it does not install QMD or the web bundle.
- `--no-init` skips current-project initialization/enrollment.

Diagnostics classify external tools such as `gh`, `claude`, and `codex` as
diagnose-only: setup prints the exact fix command but does not authenticate or
install them silently. Hive-owned pieces are bootstrappable. See
[[commands/web]] and [[commands/daemon]] for the service details.

## Backlinks

- [[commands/web]] · [[commands/daemon]] · [[operating]]
