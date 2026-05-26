---
title: hive bot
type: command
source: lib/hive/commands/bot.rb, lib/hive/bot/*
created: 2026-05-14
updated: 2026-05-25
tags: [command, bot, telegram, mobile, json]
---

**TLDR**: `hive bot SUBCOMMAND` runs the Telegram mobile surface for
human-input gates. It long-polls Telegram, ignores chats outside the
global allowlist, renders waiting/status rows with inline buttons, and
dispatches the same `hive` workflow verbs the daemon and CLI already
use. It is a subprocess caller, not a second approval engine.

## Subcommands

```
hive bot start [--foreground] [--dry-run]
hive bot stop [--json]
hive bot status [--json]
hive bot reload [--json]
hive bot tail
hive bot install [--force] [--json]
```

| Subcommand | Behavior |
|-----------|----------|
| `start` | Loads `bot:` from the global config, requires `HIVE_TELEGRAM_BOT_TOKEN`, writes the bot PID file, then starts the long-poll/status/reaper supervisor. By default it daemonizes so the shell prompt returns immediately. With `--foreground`, it stays attached for systemd, launchd, or debugging. With `--dry-run`, inbound Telegram parsing and notifications still run but child `hive ...` dispatches are reported rather than spawned. A second live bot exits `75 (TEMPFAIL)`. |
| `stop` | Sends `SIGTERM` to the PID file's process and waits up to `bot.shutdown_grace_sec`, then escalates to `SIGKILL`. Idempotent when no bot is running. With `--json`, emits `hive-bot-stop.v1`. |
| `status` | Reports running/not-running and exits `0` when running, `1` when not. With `--json`, emits `hive-bot-status.v1` with `running`, `pid`, `uptime_sec`, `pid_file`, and `log_file`. |
| `reload` | Sends `SIGHUP`; the supervisor reloads config at the next loop boundary while preserving in-flight children and conversations. With `--json`, emits `hive-bot-reload.v1`. |
| `tail` | Streams `~/.local/state/hive/logs/bot.log`; exits 1 if the log does not exist. |
| `install` | (Re)writes the platform-native unit (`~/.config/systemd/user/hive-bot.service` on Linux, `~/Library/LaunchAgents/local.hive-bot.plist` on macOS) and enables autostart. Mirrors `hive daemon install` via the shared `ServiceInstaller::Base`: always installs with `autostart: true`. Without `--force`, refuses to overwrite a pre-existing unit that differs from the template (exit `64` USAGE, message pointing at `--force`). With `--force`, saves the previous content to a timestamped `<path>.bak-YYYYMMDDTHHMMSSZ` via atomic write, then restarts/reloads the service so new `Environment=` lines take effect. A service-manager failure exits `70` (SOFTWARE); a host with no systemd-user manager still gets the unit written but exits `0` with the `unsupported` outcome. Units point at the user-facing wrapper path when installers provide it, so `hv` invocations survive Apache Hive shadowing `hive`. `hive uninstall` tears this unit back down. With `--json`, every outcome (success and error) emits a `hive-bot-install.v1` envelope. |

## Commands in Telegram

| Slash command | Behavior |
|--------------|----------|
| `/status [--json] [project]` | Renders actionable rows from `hive status --json` as `Title… — Stage`; when a project name is supplied, filters to that project. Pass `--json` to receive the raw `hive-status` envelope instead of human prose (intended for automated callers). The prose form is intentionally not a versioned contract — automated tooling that needs a stable shape MUST use `--json`, which echoes the `hive-status` envelope schema. |
| `/queue` | Same actionable-row view as `/status`, without a project filter. |
| `/idea <text>` | Shows a project picker. Tapping a project dispatches `hive new <project> <text>`. |
| `/answer <slug>` | Starts Path B brainstorm answering; each free-text reply writes the current unanswered `### A<N>.` block under the task lock. |
| `/approve <slug>` | Dispatches `hive approve <slug> --json` for the direct approval surface. Inline approval buttons usually use the workflow verb instead. |
| `/autofix <slug>` | Dispatches the same `hive markers clear` + retry-verb sequence the inline 🔧 Autofix button dispatches. Resolves the slug against the latest `StatusWatcher` snapshot. Replies `"Hive has no automatic recovery for this state - open it on a laptop."` for manual-only markers and `"No retry verb for stage X."` when the stage has none. |
| `/details <slug>` | Dispatches `hive status --diagnose <slug> --project <project> --stage <stage> --json` — same payload as the inline "Show details" button. |
| `/done` | Ends the active brainstorm conversation and dispatches `hive run <slug> --json` so the brainstorm runner re-checks the round. |
| `/help` | Lists the supported command set. |

Free text outside an active answer conversation is rejected with a
`/help` hint. Unauthorized chats receive no reply.

The `/status` (and `/queue`) reply lists actionable rows as
`Title — Stage` text, and attaches an **inline keyboard** with one
button per row that has a Telegram-side next step. Tapping a button
acts on that task in-chat. Buttons are used rather than rendered
`/command <slug>` text links because Telegram's `bot_command` message
entity covers only the `/command` token, not the argument — tapping a
rendered `/answer <slug>` would send just `/answer` and hit the usage
hint, dropping the slug. Inline callback buttons carry the full
payload on tap. Per-row button mapping (built via
`Supervisor#status_action_button`, reusing `NotificationBuilders`
callback constructors so the callbacks are byte-identical to the
push-notification buttons):

- `needs_input` + `2-brainstorm` + `waiting` → **✏️ answer** (`answer:` callback)
- `ready_to_*` → **✅ approve** (`approve:<verb>:` callback)
- recovery row, retryable → **🔧 autofix** (`autofix:` callback)
- recovery row, manual-only → **🔍 details** (`details:` callback)
- anything else (e.g. in-flight `agent_running`) → no button

The reply stays text-only when no row is actionable. The `/answer`,
`/approve`, `/autofix`, `/details` slash commands remain typeable
(and appear in the quick-actions menu) for operators who prefer
typing or scripting.

On bot start the supervisor calls Telegram's `setMyCommands` so the
blue quick-actions menu (shown when the operator taps the `/` icon in
the chat input) surfaces `/idea`, `/status`, `/queue`, `/answer`,
`/approve`, `/autofix`, `/details`, `/done`, and `/help` with
human-readable descriptions. This is a one-shot idempotent RPC at
start — it is not re-issued on SIGHUP/config reload because the
command list does not change with config. A network failure during
registration is logged as `:send_failure` with
`source: "set_my_commands"` and does not block `poll_loop` from
starting. The command list and descriptions live in
`Hive::Bot::Supervisor::BOT_COMMANDS`.

## Inline actions

Push notifications use callback data that routes to:

- Stage approvals: `Approve` dispatches `hive brainstorm|plan|develop|review|pr|archive <slug> --from <stage> --project <project> --json`.
- Brainstorm waits: `Answer in chat` starts the same `/answer` conversation.
- Review triage: `Accept all` / `Reject all` dispatch `hive accept-finding` or `hive reject-finding` with `--all`.
- Recovery markers: `Autofix` appears only when the diagnostic suggested action is `retry`. It dispatches `hive markers clear ... --name <MARKER> --match-attr <key=value> --json` when a marker attribute is available, then dispatches the stage's workflow verb when one exists and resets the persisted alert entry for that task. Manual-only recovery states show `Open laptop` / `Show details`; legacy `Clear and retry` buttons from older messages still route to the same guarded recovery sequence.
- `Open laptop` is an explicit no-op reply for disagreements that do not fit the MVP button set.

## Config

The bot is global, not per-project:

```yaml
bot:
  enabled: false
  chat_id_allowlist: [123456789]
  poll_interval_sec: 30
  long_poll_timeout_sec: 25
  notification_dedupe_window_sec: 300
  alert_state_file: ~/.local/state/hive/.bot.alert_state.json
  recovery_reminder_window_sec: 28800
  pid_file: ~/.local/state/hive/.bot.pid
  log_file: ~/.local/state/hive/logs/bot.log
  last_seen_state_file: ~/.local/state/hive/.bot.last_seen_update_id
```

`notification_dedupe_window_sec` is legacy compatibility surface; current
alert lifecycle dedupe is status-driven and persisted in
`alert_state_file`.

On a fresh install (or after the operator deletes `alert_state_file`)
the first status tick **silently seeds** every currently-failing row
into the store and emits a single `:fresh_install_seeded` log event
instead of firing an alert per backlog row. Subsequent ticks alert on
deltas only. To suppress this and force an alert for every active row
on first start, do not configure `alert_state_file` (running without
persistence means every restart is a burst — accept the trade-off).

`HIVE_TELEGRAM_BOT_TOKEN` is the only supported token source. Missing
token or empty allowlist makes `hive bot start` raise `Hive::ConfigError`
(exit 78). Unknown chat IDs are logged once per bot lifetime and ignored
silently.

`hive bot start` also loads `~/.config/hive/.env` (next to `config.yml`)
into `ENV` at startup so operators don't have to wire the token into a
shell rc file. Format is the conventional `KEY=value` per line; outer
single or double quotes are stripped; `#` starts a comment; existing env
vars take precedence (a manual `export HIVE_TELEGRAM_BOT_TOKEN=...`
always wins).

Example `~/.config/hive/.env`:

```
HIVE_TELEGRAM_BOT_TOKEN=123456789:AAAAa-BBBb-CCCC
```

The file is read once at `hive bot start` time; `hive bot reload`
re-reads `config.yml` but NOT `.env` (tokens are not reload-safe; restart
the bot after rotating).

## Structured log

`~/.local/state/hive/logs/bot.log` is one JSON document per line with schema
`hive-bot-log.v1`. The event enum is closed in
`Hive::Bot::Logger::EVENTS`; unknown events raise at the call site.

The schema evolves additively: new event values may be appended to
`v1` without changing `schema_version`. Breaking changes (removing an
event, renaming it, or changing the payload shape of an existing
event) require a `v2` schema file alongside `v1`, bumped `$id`, and
synchronized `schema_version` constant. Downstream consumers that pin
on the `$id` URL must therefore tolerate unknown event values when
parsing v1; that's the read-side compat invariant.
Events include `bot_started`, `poll_failure`, `update_received`,
`notification_sent`, `dispatched_command`, `command_completed`,
`codex_spawned`, `answer_written`, `reconnect_summary`, and `fatal`.

## Autostart

`hive bot install` gives the bot the same reboot-survivable per-user
service the daemon has (`hive daemon install`), built on the shared
`Hive::Commands::ServiceInstaller::Base`. Key differences from the daemon:

- **Opt-in.** Unlike the daemon — which the Hive installer enables at
  install time as core infrastructure — the bot service is installed only
  by the explicit `hive bot install`. It is never auto-run by `install.sh`
  or `hive init`, because the bot needs a token and an allowlist the
  operator must set up first.
- **One command.** `install` both enables autostart (survives
  reboot/login) and starts the bot now (`systemctl --user enable --now` /
  `launchctl load`). There is no separate `hive bot start` step for the
  managed bot.
- **No inline secret.** The unit runs `hive bot start --foreground` and the
  bot loads `~/.config/hive/.env` itself (`Hive::EnvFile.load!`), so
  `HIVE_TELEGRAM_BOT_TOKEN` never appears in the unit file. The unit only
  carries the Ruby-shim `PATH` (mise/rbenv/asdf detection) so the `hive`
  binary resolves under the service manager's minimal environment.
- **Single instance.** The service and a manual `hive bot start` cannot run
  two bots at once — the `.bot.pid` lock makes the second exit
  `75 (TEMPFAIL)`. `hive bot start` remains the manual/debug path and the
  fallback on hosts without systemd-user / launchd.
- **Teardown.** `hive uninstall` stops, disables, and removes the bot unit
  alongside the daemon unit. There is no standalone `hive bot uninstall`.

## Exit codes

| Subcommand | Code | Condition |
|------------|------|-----------|
| `start` | 0 | Background bot started, or foreground bot exited cleanly |
| `start` | 75 | Another bot is already running |
| `start` | 78 | Token/allowlist/config is missing or malformed |
| `stop` | 0 | Always, including not-running |
| `status` | 0 | Bot is running |
| `status` | 1 | Bot is not running |
| `reload` | 0 | SIGHUP sent |
| `reload` | 1 | Bot is not running |
| `tail` | 0 | Stream ended via Ctrl-C |
| `tail` | 1 | Log file missing |
| `install` | 0 | Unit written/upgraded/unchanged and autostart enabled, or written on a host with no service manager (`unsupported` outcome) |
| `install` | 64 | Existing unit differs from the template; re-run with `--force` (USAGE) |
| `install` | 70 | Service manager rejected enable/load (SOFTWARE) |

## Backlinks

- [[modules/bot]]
- [[cli]] · [[operating]]
- [[decisions]] (ADR-026)
- [[architecture]]
