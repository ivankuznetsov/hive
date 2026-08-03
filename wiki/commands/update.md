---
title: hive update
type: command
source: lib/hive/commands/update.rb, lib/hive/commands/migrate_all.rb, lib/hive/install_channel.rb
created: 2026-05-21
updated: 2026-08-03
tags: [command, install, update, migration]
---

**TLDR**: `hive update` delegates to the channel that installed Hive, then
runs `hive migrate --all` through the newly installed binary. It reports both
phases, names project migration failures, and prints exact recovery commands.

## Usage

```bash
hive update [--dry-run]
```

`--dry-run` prints the selected channel, updater command, and post-update
migration command without executing either one.

## Channel detection

`Hive::InstallChannel.detect` probes marker paths in priority order:

1. `${XDG_DATA_HOME:-~/.local/share}/hive/install-channel`.
2. `$HIVE_PREFIX/hive/install-channel` when `HIVE_PREFIX` is set.
3. macOS Homebrew marker paths under a valid Homebrew prefix.
4. `/usr/share/hive/install-channel` for system packages.

A missing marker means `dev`, the git-checkout fallback. Malformed markers fail closed with `Hive::ConfigError` instead of falling through to a lower-priority marker.

`install.sh --prefix=<dir>` writes both `install-channel` and `install-prefix` sidecars so the bash-channel updater can re-use the original prefix without requiring `HIVE_PREFIX` to be exported again.

## Channel actions

| Channel | Action |
|---------|--------|
| `brew` | `brew upgrade ivankuznetsov/hive/hive` |
| `aur` | `yay -Syu hive-bin`, falling back to `paru` when `yay` is unavailable |
| `bash` | downloads `https://raw.githubusercontent.com/ivankuznetsov/hive/main/install.sh` to a temp file, then runs it, preserving the detected prefix when available |
| `dev` | prints `git pull && bundle install && hive migrate --all` guidance and exits 0 |

The bash channel deliberately downloads to a tempfile rather than piping remote script bytes into a shell. Helper preflight checks make missing `brew`, `curl`, `yay`, or `paru` errors actionable.

## Automatic migration

The package updater runs as a child process so the current command can continue
after installation. When it succeeds, Hive resolves the updated executable
again and invokes `<updated-hive> migrate --all`; migrations therefore execute
with the newly installed code, not the old in-memory implementation.

`hive migrate --all` checks global recovery state and then every registered
project. Output includes a global-state check, `[N/total]` progress for each
project, per-project success, and a final migrated/failed count. Project
failures do not hide later projects: the fleet pass continues, prints a
one-line error plus a shell-escaped recovery command using the active `hive` or
`hv` wrapper, and exits non-zero after the complete inventory has been
attempted. A missing registered path names restore, `forget`, and `prune`
options instead of suggesting a project migration that cannot run.

If the channel updater fails, migration is not started. If the updated binary
cannot be resolved or the fleet migration exits non-zero, `hive update` reports
that distinction and prints the exact `hive migrate --all` command to retry.
Project migrations defer daemon restart requests so a changed fleet triggers
at most one restart, after every registered project has been attempted.

## Nudge command (shared with the update flow)

`Hive::Commands::Update.nudge_command(channel)` returns `hive update` for every
installed channel and `nil` for `dev` (a git clone has no single automatic
update action). The daemon-driven [[update-flow]] uses this string when it
records a per-version nudge. Keeping the user-facing command channel-neutral
ensures every guided update includes the automatic migration phase; the update
command itself still selects brew, `yay`/`paru`, or the bash installer.

## Tests

- `test/unit/commands/update_test.rb` covers channel selection, dry-run output,
  bash-prefix reuse, helper preflights, AUR fallback, update/migration ordering,
  status output, and readable recovery failures.
- `test/unit/commands/migrate_all_test.rb` covers fleet progress, global-state
  migration, continue-after-failure behavior, readable errors, and recovery
  commands.
- `test/unit/install_channel_test.rb` covers marker reads/writes, XDG paths, Homebrew marker probing, prefix marker precedence, and fail-closed invalid markers.

## Backlinks

- [[cli]] · [[operating]] · [[modules/config]] · [[update-flow]]
