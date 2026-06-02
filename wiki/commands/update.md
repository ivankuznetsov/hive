---
title: hive update
type: command
source: lib/hive/commands/update.rb, lib/hive/install_channel.rb
created: 2026-05-21
updated: 2026-05-27
tags: [command, install, update]
---

**TLDR**: `hive update` reads the install-channel marker and delegates to the same channel that installed Hive. It never swaps its own binary directly and never guesses across channels.

## Usage

```bash
hive update [--dry-run]
```

`--dry-run` prints the selected channel and command without executing it.

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
| `dev` | prints `git pull && bundle install` guidance and exits 0 |

The bash channel deliberately downloads to a tempfile rather than piping remote script bytes into a shell. Helper preflight checks make missing `brew`, `curl`, `yay`, or `paru` errors actionable.

## Nudge command (shared with the update flow)

`Hive::Commands::Update.nudge_command(channel)` returns the canonical one-line update command per channel — `brew upgrade ivankuznetsov/hive/hive` for brew, and `hive update` for both `aur` and `bash` — and `nil` for `dev` (git clone has no single canonical command). The daemon-driven [[update-flow]] uses this string when it records a per-version nudge. The `aur` and `bash` channels nudge `hive update` rather than a raw package-manager command: `aur` because the real updater picks `yay` or `paru` at runtime (a hardcoded `yay …` would fail for paru-only users), and `bash` because in-place auto-update (U7) isn't built yet.

## Tests

- `test/unit/commands/update_test.rb` covers channel selection, dry-run output, bash-prefix reuse, helper preflights, malformed marker handling, and AUR helper fallback.
- `test/unit/install_channel_test.rb` covers marker reads/writes, XDG paths, Homebrew marker probing, prefix marker precedence, and fail-closed invalid markers.

## Backlinks

- [[cli]] · [[operating]] · [[modules/config]] · [[update-flow]]
