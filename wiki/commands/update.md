---
title: hive update
type: command
source: lib/hive/commands/update.rb, lib/hive/install_channel.rb, install.sh
created: 2026-05-21
updated: 2026-08-30
tags: [command, install, update, migration]
---

`hive update [--dry-run]` runs the owning install channel's updater, resolves
its installed binary, then runs `hive runtime status`. `--dry-run` prints both
commands. No migration or cutover confirmation is performed.

## Channel detection

`Hive::InstallChannel.detect` probes marker paths in priority order:

1. `${XDG_DATA_HOME:-~/.local/share}/hive/install-channel`.
2. `$HIVE_PREFIX/hive/install-channel` when `HIVE_PREFIX` is set.
3. macOS Homebrew marker paths under a valid Homebrew prefix.
4. `/usr/share/hive/install-channel` for system packages.

A missing marker means `dev`, the git-checkout fallback. Malformed markers fail closed with `Hive::ConfigError` instead of falling through to a lower-priority marker.

`install.sh --prefix=<dir>` normalizes `<dir>` to an absolute path before it writes both `install-channel` and `install-prefix` sidecars, so the bash-channel updater can re-use relative or `~/...` caller input from any later working directory without requiring `HIVE_PREFIX` to be exported again.

## Channel actions

| Channel | Action |
|---------|--------|
| `brew` | `brew upgrade ivankuznetsov/hive/hive` |
| `aur` | `yay -Syu hive-bin`, falling back to `paru` when `yay` is unavailable |
| `bash` | downloads `https://raw.githubusercontent.com/ivankuznetsov/hive/main/install.sh` to a temp file, then runs it, preserving the detected prefix when available |
| `dev` | prints `git pull && bundle install && hive runtime status` guidance and exits 0 |

The bash channel deliberately downloads to a tempfile rather than piping remote script bytes into a shell. Helper preflight checks make missing `brew`, `curl`, `yay`, or `paru` errors actionable.
The installer binds cosign verification to the resolved release tag whether
that tag came from `HIVE_VERSION`/`--version` or the latest-release API; the
latest-version path therefore authenticates the same exact workflow identity
as an explicitly pinned install.

## Current runtime validation

Update never imports historical state, changes schema versions, or replaces
package-owned launchers. A channel failure prevents validation; a missing updated
binary or failed runtime check reports the exact error and next diagnostic command.
Fresh installations use `hive setup`. Older state uses the
[agent migration guide](../../docs/guides/current-format-migration.md).

The daemon nudge remains `hive update` for installed channels and absent for dev.
Tests in `test/unit/commands/update_test.rb` cover updater ordering, dry runs,
manager selection and validation failure reporting.
