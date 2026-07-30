---
title: hive update
type: command
source: lib/hive/commands/update.rb, lib/hive/install_channel.rb
created: 2026-05-21
updated: 2026-07-29
tags: [command, install, update]
---

**TLDR**: `hive update` reads the install-channel marker and delegates to the same channel that installed Hive. Before a real update it fences a verified running daemon, then restarts only a daemon it stopped through the post-update wrapper. It never swaps its own binary directly and never guesses across channels.

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

## Daemon quiescence around an update

Before it invokes a real channel updater, `hive update` first checks whether the
local Hive daemon is running. If it is, Hive captures the daemon and its
supervised child/process-group identities, runs the existing verified
`hive daemon stop` lifecycle, and waits for a generation-bound shutdown
acknowledgement written only after dispatcher admission is closed and the
existing `ChildSupervisor` has drained. The supervisor folds repeated
post-`TERM` descendant snapshots into that final inventory. The updater then
independently refuses package replacement unless the old PID, every observed
child, and every observed process group are gone. This prevents an old
installed daemon from writing released JobStore v2 state while candidate code
could begin its one-way conversion.

After a successful updater invocation, Hive executes
`<stable-invoked-hive> refactor-patrol-migrate-installed` before any daemon
restart, even when no daemon was running. That fresh candidate process backfills
registry identities, migrates the updater user's complete profile, persists,
and prints its typed user-profile result. AUR additionally runs the root-only
`--all-users` coordinator from its package hook and enables the hourly retry
timer in `--resume` mode. Root-run `install.sh` performs the all-user sweep
once. Homebrew and
non-root install.sh cannot acquire administrator authority: they explicitly
report current-user-only coverage and require
`sudo hive refactor-patrol-migrate-installed --all-users` on a shared machine.
First use is only a fallback. A
failed/retryable project row is an observed completed sweep, not a process
crash. If the candidate command fails structurally, a daemon that was running
before the update is still restarted in `ensure`, then the candidate failure
is returned. Candidate-owned daemon restarts detach from migration capture
stdio, so a live restarted daemon cannot keep an updater or all-user
coordinator waiting for pipe EOF.

Hive starts a daemon only when it had stopped one, using the stable invoked
wrapper so the new process loads the post-update package generation. If package
activation fails, the same restart path restores service availability from the
active wrapper before the update error is returned. `--dry-run` and
missing-helper failures do not stop or restart a daemon. If the shutdown
acknowledgement never arrives, Hive does not automatically restart across that
uncertain quiescence: the error warns that the daemon may already be stopped
and directs the operator to run `hive daemon status --json`, then (only if
stopped) `hive daemon start --detach`. A manual candidate JobStore open has its
own migration writer fence, so this command lifecycle is not its only
protection.

## Nudge command (shared with the update flow)

`Hive::Commands::Update.nudge_command(channel)` returns the canonical one-line update command per channel — `brew upgrade ivankuznetsov/hive/hive` for brew, and `hive update` for both `aur` and `bash` — and `nil` for `dev` (git clone has no single canonical command). The daemon-driven [[update-flow]] uses this string when it records a per-version nudge. The `aur` and `bash` channels nudge `hive update` rather than a raw package-manager command: `aur` because the real updater picks `yay` or `paru` at runtime (a hardcoded `yay …` would fail for paru-only users), and `bash` because in-place auto-update (U7) isn't built yet.

## Tests

- `test/unit/commands/update_test.rb` covers channel selection, dry-run output,
  bash-prefix reuse, helper preflights, old-writer quiescence,
  supervised-child proof, stopped/running daemon candidate-sweep ordering,
  restart on structural candidate failure, acknowledgement recovery guidance,
  malformed marker handling, and AUR helper fallback.
- `test/unit/install_channel_test.rb` covers marker reads/writes, XDG paths, Homebrew marker probing, prefix marker precedence, and fail-closed invalid markers.

## Backlinks

- [[cli]] · [[operating]] · [[modules/config]] · [[update-flow]]
