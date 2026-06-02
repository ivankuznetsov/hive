---
title: hive daemon
type: command
source: lib/hive/commands/daemon.rb, lib/hive/daemon/*
created: 2026-05-06
updated: 2026-05-26
tags: [command, daemon, automation, json]
---

**TLDR**: `hive daemon SUBCOMMAND` is the operator surface for the
auto-advancing dispatcher (ADR-024). One long-running process polls
`hive status --json` every 30s, dispatches workflow verbs (`hive plan`
/ `develop` / `open-pr` / `review` / `artifacts` / `finalize`) on tasks ready to advance, and
auto-archives 8-finalize → 9-done after `gh pr view` reports `MERGED`. Stops
only at human-input gates: `_WAITING` markers (Q&A / triage), recovery
markers (`_STALE` / `_ERROR`), and 8-finalize while the PR is still open on
GitHub.

## Subcommands

```
hive daemon start [--detach] [--dry-run]
hive daemon stop
hive daemon status [--json]
hive daemon reload
hive daemon tail
hive daemon install [--force]
hive daemon enable  PROJECT | --all  [--json]
hive daemon disable PROJECT | --all  [--json]
```

| Subcommand | Behavior |
|-----------|----------|
| `start`    | Acquires the PID file (`~/Dev/hive/.daemon.pid`); without `--detach` runs in the foreground. With `--detach` calls `Process.daemon(true, true)` and the parent returns immediately. With `--dry-run` logs every dispatch decision but does NOT spawn child `hive ...` processes. Refuses with exit `75 (TEMPFAIL)` if a live daemon already holds the PID file. |
| `stop`     | Sends `SIGTERM` to the running daemon's PID. Waits up to `daemon.shutdown_grace_sec` (default 600s) for the daemon to exit, then escalates to `SIGKILL`. Idempotent: `stop` with no PID file exits 0 with `daemon not running` on stderr; a stale PID file (process gone) is removed and the call exits 0. With `--json`, emits a `hive-daemon-stop` envelope (fields: `running`, `was_running`, `stale_pid?`, `reason?` — `pid_reused` / `unverified` for safety bailouts). |
| `status`   | Reports running / not running. Exit code 0 if running, 1 if not. With `--json`, emits a `hive-daemon-status` envelope with `running`, `pid`, `uptime_sec`, `pid_file`, `log_file`, plus the autostart-service state `service_installed`, `service_enabled`, and `unit_path` (read-only probe) so an agent can tell whether `hive daemon install` has run without a mutating call. |
| `reload`   | Sends `SIGHUP` to the running daemon's PID, which triggers config reload at the next tick boundary. In-flight children continue uninterrupted. Exit 1 if no daemon running. With `--json`, emits a `hive-daemon-reload` envelope (`ok`, `reason`, `pid`, `message`). |
| `tail`     | `tail -F` semantics on `~/Dev/hive/logs/daemon.log` (self-implemented; doesn't shell out to the `tail` binary). Exit 1 if the log file doesn't exist. |
| `install`  | (Re)writes the platform-native unit file (`~/.config/systemd/user/hive-daemon.service` on Linux, `~/Library/LaunchAgents/local.hive-daemon.plist` on macOS) and starts/enables the service. Installers and agent-assisted setup run this by default so daemon autostart is global install-time infrastructure, independent of any project. Without `--force`, refuses to overwrite a pre-existing unit (preserving operator hand-edits); exit `64` (USAGE) with a message pointing at `--force` so automation can branch without clobbering local changes. With `--force`, saves the previous content to a timestamped `<path>.bak-YYYYMMDDTHHMMSSZ` (rotated, never overwritten) via atomic write, then — only when an existing unit was actually overwritten (the `upgraded` outcome) — restarts the running daemon on Linux / unloads-then-loads on macOS so new `Environment=` lines take effect (a first-time `--force` install with no prior unit just starts/enables, no restart). A service-manager failure (systemctl reload/enable, or launchctl load rejecting the unit) exits `70` (SOFTWARE). A host with no systemd-user manager at all is different: the unit is still written, but autostart cannot be enabled, so it exits `0` with the `unsupported` outcome (and `target_path` set to the written unit) — a known-platform limitation, not a failure. With `--json`, every outcome (success and error) emits a `hive-daemon-install.v1` envelope. Units point at the user-facing wrapper path when installers provide it, so bash/Homebrew installs preserve the GEM_HOME/GEM_PATH wrapper across login/reboot; `hv` invocations remain valid when Apache Hive shadows `hive`. Use this after upgrading hive when the unit template has changed or when autostart needs repair. |
| `enable`   | Sets `daemon.enabled: true` in `<project>/.hive-state/config.yml`. This enrolls a project for dispatch; it does not install, start, or autostart the global daemon service. Surgical line-level YAML editor (upsert) preserves comments, key order, and file-mode bits across enable/disable flips; rejects inline-flow `daemon: { ... }`, CRLF endings, and 4-space-indented children before any write. Atomic write goes via tempfile + `flock(LOCK_EX)` + `fsync` + rename; tempfile is ensure-cleaned on rename failure (ENOSPC / EACCES / EXDEV). Pre-flight (`preflight_targets`) validates every target before any write so `--all` cannot half-flip the registry on a bad middle project. Pass a registered project name OR `--all` (mutually exclusive — passing both raises USAGE 64). Exit 64 on missing/unknown target / not-initialised project / no registered projects. With `--json`, emits a `hive-daemon-enroll` envelope on success and an `EnrollErrorKind` JSON error envelope on failure (`missing_project` / `unknown_project` / `project_and_all` / `not_initialised` / `no_projects` / `config` / `internal`); YAML parse failures surface as `Hive::ConfigError` (exit 78). |
| `disable`  | Same shape as `enable`, sets `daemon.enabled: false`. The next dispatcher tick honours the change automatically (per-tick enable-cache invalidation); `hive daemon reload` is optional for instant pickup. |

## What the daemon dispatches

Per `Hive::Daemon::Policy.decide`, the daemon classifies each `hive
status --json` task row by `next_action.kind` (a `Hive::Schemas::TaskActionKind`
value) and routes:

| `tasks[].action`      | Daemon action                                |
|-----------------------|----------------------------------------------|
| `ready_to_brainstorm` | Dispatch `hive brainstorm <slug>` (1→2)      |
| `ready_to_plan`       | Dispatch `hive plan <slug> --from 2-brainstorm` (2→3) |
| `ready_to_develop`    | Dispatch `hive develop <slug> --from 3-plan` (3→4) |
| `ready_to_open_pr`    | Dispatch `hive open-pr <slug> --from 4-execute` (4→5) |
| `ready_for_review`    | Dispatch `hive review <slug> --from 5-open-pr` (5→6) |
| `ready_to_artifacts`  | Dispatch `hive artifacts <slug> --from 6-review` (6→7) |
| `ready_to_finalize`   | Dispatch `hive finalize <slug> --from 7-artifacts` (7→8) |
| `ready_to_archive`    | **Hand off to PrMergeWatcher**: poll `gh pr view` until `MERGED`, then dispatch `hive archive <slug> --from 8-finalize` (8→9) |
| `needs_input` at `3-plan` | **Auto-dispatch immediately.** Plan-stage `:waiting` is an approval pause, not a Q&A wait — `daemon.enabled: true` is the durable consent. `Hive::Daemon::PlanApproval.prepare` rewrites the row's `hive plan ...` command to `hive develop ...` and flips the `:waiting` marker to `:complete` before dispatch so the workflow verb's terminal-marker gate (`VALID_TERMINAL_MARKERS`) accepts the advance. Logged as `:dispatched` with `trigger: "plan_approval"`. |
| `needs_input` (any other stage) | Dispatch only if state-file mtime moved AND `daemon.edit_debounce_sec` elapsed since last edit. The debounce guards mid-save partial drafts. Brainstorm/execute/review WAITING represent actual user-authored answers; auto-dispatch without an edit would either spam the agent or skip real user input. The `[project, slug] → mtime` baseline this compares against is **persisted** (`daemon_dispatch_baselines.json` under the state home, beside `.daemon.pid`), so a daemon restart no longer re-strands a task answered while it was down — see [[modules/daemon]] "Persisted dispatch baselines". **Brainstorm Q&A gate:** mtime-debounce alone can't tell "answered 1 of 3, still going" from "done" — each Telegram answer bumps the file mtime — so a `2-brainstorm` `needs_input` row whose `brainstorm.md` still has unanswered `### Q{n}.` slots is **held** (`Policy :wait_for_answers`, logged `:skipped reason=answers_pending`) until every question is answered, whether they arrive one-at-a-time via the bot or in one editor save. See [[modules/daemon]] "Brainstorm answers-pending gate". |
| `recover_execute`, `recover_review` | Skip — recovery markers are explicit human-input gates. |
| `agent_running`       | Skip — task is in flight; per-task `.lock` would block double-spawn anyway. |
| `archived`            | Skip — terminal. |
| `error`               | Skip. |

`agent_running` rows also feed daemon capacity accounting when status
has positive liveness evidence. The dispatcher counts both rows with a
live recorded Claude PID and rows with `live_task_lock: true` (a verified
`hive run` task-lock holder before Claude has attached). This keeps a
daemon restart during auto-rebase or other pre-agent work from spawning
extra tasks past `max_concurrent_runs` / `max_concurrent_per_project`.

The closed-default policy means any unknown future `TaskActionKind`
value falls through to `:skip` until the daemon is taught about it.

## Per-project enrollment

Each project's `.hive-state/config.yml` carries:

```yaml
daemon:
  enabled: true   # asked at `hive init`, default Y; project enrollment only
```

Newly-init'd projects render `daemon.enabled: true` from the init
prompt's default. **Legacy projects** whose YAML predates the `daemon:`
key fall back to `Config::DEFAULTS["daemon"]["enabled"] = false` — same
"don't silently flip legacy projects" pattern ADR-023 used for
stage agents. Operators of legacy projects opt in by adding `daemon: { enabled: true }` and running `hive daemon reload`.

## Concurrency caps

All under `daemon:` in `~/Dev/hive/config.yml`:

| Key | Default | Purpose |
|-----|---------|---------|
| `poll_interval_sec` | 30 | Tick cadence for status polling. Min 5. |
| `edit_debounce_sec` | 30 | Settle window for `kind: edit` resumes. 0 disables debounce. |
| `pr_merge_poll_interval_sec` | 300 | PrMergeWatcher cadence (per-task). Min 60 to respect GitHub rate limits. |
| `max_concurrent_runs` | 3 | Global cap. Raise carefully — multiplies cost ceiling. |
| `max_concurrent_per_project` | 3 | Per-project burst cap; set below the global cap only when you want cross-project sharing. |
| `max_runs_per_day_per_project` | 50 | Circuit breaker for runaway loops. |
| `transient_retry_backoff_sec` | 60 | Base of `60 → 120 → 300 s` backoff schedule. |
| `shutdown_grace_sec` | 600 | TERM→KILL window for in-flight children on `daemon stop`. |
| `log_file` | `~/Dev/hive/logs/daemon.log` | Structured-log destination. |
| `log_max_bytes` | 10485760 | 10 MB rotation threshold. |
| `log_max_files` | 5 | 5 × 10 MB = 50 MB log budget. |

## Retry policy on child exit

| Exit | Constant | Action |
|------|----------|--------|
| 0 | `SUCCESS` | 5-min cooldown on `(project, slug)`; daily counter +1 |
| 3 | `TASK_IN_ERROR` | No retry; marker now classifies row as `recover_*` → Policy returns `:skip` |
| 4 | `WRONG_STAGE` | 5-min cooldown (race or classifier bug) |
| 64 | `USAGE` | Quarantine `(project, slug)` for daemon lifetime |
| 70 / 1 | `SOFTWARE` / `GENERIC` | Transient: 60→120→300 s backoff, then quarantine |
| 75 | `TEMPFAIL` | Refund daily slot, allow immediate retry next tick |
| 78 | `CONFIG` | Drop the entire project from active dispatch until daemon restart |

## Structured log

`~/Dev/hive/logs/daemon.log` is one JSON document per line:

```json
{"ts":"2026-05-06T12:00:00Z","schema":"hive-daemon-log","schema_version":1,"event":"dispatched","pid":12345,"project":"writero","slug":"fix-x","stage":"6-review","command":"hive run fix-x --json","dry_run":false}
```

Closed `event` enum (`Hive::Daemon::Logger::EVENTS`). Adding an event
without updating the enum raises `ArgumentError` at the call site so
new events are caught at CI rather than logged silently.

## Operational notes

- **Day-2 guide is at [[operating]]** — service setup (`hive daemon
  install`), project enrollment (`hive daemon enable PROJECT|--all`),
  autostart on Linux (systemd-user) and macOS (launchd), dry-run
  shakedown, and troubleshooting.
- **First-time rollout:** `hive daemon start --dry-run` for ~24 hours
  before going live. Inspect `daemon.log` to validate dispatch
  decisions. Then `hive daemon stop` and re-start without `--dry-run`.
- **Cost runaway response:** `hive daemon stop` is one command. To
  exclude a single project mid-flight: `hive daemon disable PROJECT`
  (the next tick honours it automatically). In-flight children
  continue to completion.
- **macOS / Linux:** `Process.daemon` works on both; the daemon does
  not require `systemd`. Sample autostart units ship at
  `examples/systemd/hive-daemon.service` (Linux) and
  `examples/launchd/hive-daemon.plist` (macOS).
- **Pausing a single task:** edit the state file to remove the terminal
  marker (e.g., delete `<!-- EXECUTE_COMPLETE -->`) so the row no
  longer classifies as advance-ready. Daemon will skip until you write
  the marker back.

## Exit codes

| Subcommand | Code | Condition |
|------------|------|-----------|
| `start`    | 0    | (foreground daemon exited cleanly) |
| `start`    | 75   | Another daemon already running (TEMPFAIL) |
| `stop`     | 0    | Always (idempotent) |
| `status`   | 0    | Daemon is running |
| `status`   | 1    | Daemon is not running |
| `reload`   | 0    | SIGHUP sent successfully |
| `reload`   | 1    | Daemon is not running |
| `tail`     | 0    | Stream ended via Ctrl-C |
| `tail`     | 1    | Log file does not exist |
| (any)      | 64   | Unknown subcommand |

## Backlinks

- [[cli]] · [[commands/run]] · [[commands/status]] · [[commands/approve]]
- [[modules/daemon]]
- [[decisions]] (ADR-024)
- [[architecture]]
