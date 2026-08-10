---
title: Update flow (daemon-driven version check + nudge)
type: feature
source: lib/hive/update_check.rb, lib/hive/update_check/state.rb, lib/hive/daemon/dispatcher.rb, lib/hive/bot/supervisor.rb, lib/hive/tui/bubble_model.rb
created: 2026-05-27
updated: 2026-08-03
tags: [architecture, daemon, bot, tui, update, decision]
---

**TLDR**: The daemon checks for releases and publishes an update nudge; it does
not install unattended. When an operator runs `hive update`, however, the
channel update and all registered migrations are automatic and visibly
reported. See [[commands/update]] and [[commands/migrate]].

## Pieces

- **`Hive::UpdateCheck.latest`** — probes `https://api.github.com/repos/ivankuznetsov/hive/releases/latest`, parses `tag_name`, compares to `Hive::VERSION`. Returns a `Result(current, latest, behind)` or `nil` on **any** failure (offline, rate-limit, malformed JSON, unparseable version). Never raises — the daemon calls it on a tick and must not crash.
- **`Hive::UpdateCheck::State`** — JSON state under `Paths.state_home/update_check.json`. Holds `last_check_at` (throttle), `last_notified_version` (de-dupe), and the active `nudge` payload (`latest`/`channel`/`command`). Atomic write, fail-closed load. **Shared across processes**: the daemon writes `nudge` + `last_check_at`; the bot writes `last_notified_version`; the TUI reads `nudge`. Every operation re-reads the file first so one process can't clobber another's keys with a stale in-memory copy.
- **Dispatcher integration** (`maybe_check_for_update`) — runs at the top of each `tick`, throttled by `state.due?`. Branches on `InstallChannel.detect`: `dev` → clear nudge + skip; brew/aur/bash → set the nudge with `Update.nudge_command(channel)` and log `:update_available`. Resilient: wrapped so an error logs `:update_check_error` and never breaks the tick. Runs only when an `update_state` is injected (the daemon does; unit tests stay inert/offline).
- **TUI footer** (`bubble_model.rb`) — reads `state.nudge` on a 10s TTL cache and prepends `update <ver>: <command>` to the hint line (prepended so truncation trims the hint, not the notice).
- **Bot push** (`supervisor.rb` `push_update_nudge`, called from `status_loop`) — reads `state.nudge`; if `should_notify?(latest)`, sends to the `chat_id_allowlist` and records notified **only after a delivery succeeds** (all-failed pushes retry next tick). Once per version.

## Config

`update.check` (default `true`) gates the whole probe. `update.auto` (default `true`) is reserved for the deferred bash auto-update — currently read but not yet consulted. Loaded via `Config.load_global_update`, validated as booleans.

## Channels

- **install.sh (bash)** — the daemon nudges `hive update`; that command re-runs the installer and then migrates all registered projects. Unattended daemon installation remains deferred to U7.
- **brew** — the daemon nudges `hive update`; the command runs brew followed by automatic migration.
- **aur** — the daemon nudges `hive update`; the command picks `yay` or `paru` at runtime and then runs automatic migration.
- **dev** — git clone; skipped entirely.

## Deferred (U7)

Bash auto-update from the daemon: drain in-flight work, run `hive update`, and
re-exec into the new version (idle = active-agent snapshot empty AND
`controller.in_flight_count == 0`). The foreground updater now waits for its
installer and migration subprocesses, but unattended daemon ownership and
restart proof still need a live systemd-user spike. Non-daemon users are also
not nudged in this scope.

## Backlinks

- [[state-model]] · [[modules/config]] · [[commands/update]] · [[architecture]] · [[decisions]]
