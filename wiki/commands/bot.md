---
title: hive bot
type: command
source: lib/hive/commands/bot.rb, lib/hive/bot/*
created: 2026-05-14
updated: 2026-07-26
tags: [command, bot, telegram, mobile, json, closure]
---

**TLDR**: `hive bot SUBCOMMAND` runs the Telegram mobile surface for
human-input gates. It long-polls Telegram, ignores chats outside the
global allowlist, renders waiting/status rows with inline buttons,
captures new ideas including supported Telegram attachments and voice
notes, accepts typed or transcribed voice brainstorm answers, and
dispatches the same `hive` workflow verbs the daemon and CLI already use.
It is not a second approval engine.

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
| `status` | Reports running/not-running and exits `0` when running, `1` when not. With `--json`, emits `hive-bot-status.v1` with `running`, `pid`, `uptime_sec`, `pid_file`, `log_file`, plus the autostart-service state `service_installed`, `service_enabled`, and `unit_path` (read-only probe — `systemctl --user is-enabled` / `launchctl list`) so an agent can tell whether `hive bot install` has run without a mutating call. |
| `reload` | Sends `SIGHUP`; the supervisor reloads config at the next loop boundary while preserving in-flight children and conversations. With `--json`, emits `hive-bot-reload.v1`. |
| `tail` | Streams `~/.local/state/hive/logs/bot.log`; exits 1 if the log does not exist. |
| `install` | (Re)writes the platform-native unit (`~/.config/systemd/user/hive-bot.service` on Linux, `~/Library/LaunchAgents/local.hive-bot.plist` on macOS) and enables autostart. Mirrors `hive daemon install` through `Hive::UserService` inspect/plan/apply mechanics, with `Bot::ServiceInstaller` retaining templates and command policy and `ServiceInstaller::ResultPresenter` retaining output handling; it always installs with `autostart: true`. Without `--force`, refuses to overwrite a pre-existing unit that differs from the template (exit `64` USAGE, message pointing at `--force`). With `--force`, saves the previous content to a timestamped `<path>.bak-YYYYMMDDTHHMMSSZ` via atomic write, then — only when an existing unit was actually overwritten (the `upgraded` outcome) — restarts/reloads the service so new `Environment=` lines take effect (a first-time `--force` install with no prior unit just enables/loads, no restart). A service-manager failure exits `70` (SOFTWARE); a host with no systemd-user manager still gets the unit written but exits `0` with the `unsupported` outcome. Units point at the user-facing wrapper path when installers provide it, so `hv` invocations survive Apache Hive shadowing `hive`. `hive uninstall` tears this unit back down. With `--json`, every outcome (success and error) emits a `hive-bot-install.v1` envelope. |

## Commands in Telegram

| Slash command | Behavior |
|--------------|----------|
| `/start` | Telegram's automatic first-contact command. Replies with a short "Connected" welcome and concrete next steps (`/status`, `/idea`, `/help`) instead of falling through to the unknown-command hint. It does not dispatch workflow state. |
| `/status [--json] [project]` | Renders actionable rows from `hive status --json` as `Title… — Stage`; when a project name is supplied, filters to that project. Pass `--json` to receive the raw `hive-status` envelope instead of human prose (intended for automated callers). The prose form is intentionally not a versioned contract — automated tooling that needs a stable shape MUST use `--json`, which echoes the `hive-status` envelope schema. |
| `/queue` | Same actionable-row view as `/status`, without a project filter. |
| `/idea [text]` | Starts a new inbox idea draft. With text, the bot shows a project picker; without text, it asks for the next message's text. After project selection the draft enters file collection and shows `Done` / `Skip`. Pressing either finalizes through `Hive::Commands::New#call!`; successful capture replies `"Captured your idea in <project>. It's in the inbox - move it to 2-brainstorm to start."` Expired picker/draft callbacks ask the operator to send `/idea` again. Bare Telegram voice notes also enter idea capture: the bot transcribes the note and shows a transcript confirmation keyboard; the project picker appears only after the operator taps `Confirm`. |
| `/answer <id\|slug>` | Starts deterministic brainstorm answering; numeric ids (`9281` or `#9281`) resolve through the current status snapshot to the task slug before the conversation starts. Each free-text reply or voice note writes the current unanswered `### A<N>.` block under the task lock. The historical Path A/B distinction is compatibility-only now, and both modes use the same answer writer. Voice answers are transcribed first, then reuse the same answer writer and auto-advance replies as typed answers. |
| `/approve <id\|slug>` | Dispatches `hive approve <slug> --json` for the direct approval surface after resolving numeric ids through the current status snapshot. Inline approval buttons usually use the workflow verb instead. |
| `/autofix <id\|slug>` | Submits the latest observed recoverable row through `Hive::Recovery::API` and renders the durable coordinator receipt, matching the inline 🔧 Autofix button. Resolves an id or slug against the latest `StatusWatcher` snapshot. Replies `"Hive has no automatic recovery for this state - open it on a laptop."` for manual-only markers. |
| `/details <id\|slug>` | Resolves an id or slug against the latest `StatusWatcher` snapshot and replies with the same in-process details text as the inline "Show details" button: row summary, next-step hint, and cached diagnostic summary/detail when the row carries one. |
| `/close <id\|slug> --reason <already_delivered\|superseded> --evidence <PR-or-commit> ...` | Starts the evidence-bound operator closure flow for an active status row. Repeat `--evidence` as needed; `superseded` also uses `--successor project:slug --attestation "statement"`. The command creates only a compacted **Verify evidence** callback. The first tap re-resolves and verifies immutable evidence; a separate allowlisted **Confirm and archive** tap is still required. |
| `/done` | Ends the active brainstorm conversation and dispatches `hive run <slug> --json` so the brainstorm runner re-checks the round. There is no remaining draft-confirm substate; without an active conversation it replies with the friendly no-conversation hint. |
| `/help` | Lists the typeable workflow command set. |

Free text outside an active answer conversation is rejected with a
`/help` hint unless it is a reply-to reattach message whose quoted text
contains a project/slug or legacy "Answer mode started" slug. Unauthorized
chats receive no reply.

Media messages participate in the `/idea` flow. A photo or document with
a caption starts an idea draft using the caption as the idea text and
then shows the project picker; media without a caption starts a
file-first draft and asks for the idea text. While collecting files, each
accepted media message is staged and replies `"Attached. Send more files,
or press Done."` Supported types are jpg/jpeg/png/webp/gif/pdf/txt/md/docx.
The default caps are 20 MB per attachment and 10 attachments per draft;
oversized, unsupported, and cap-reached media receive explicit refusal
messages instead of being staged. On final capture, image attachments are
embedded in `idea.md` and non-images are linked under `assets/`.

Telegram voice notes are a parallel idea-capture input, not a slash
command. `Telegram::Update#voice?` routes bare voice messages to
`Router` intent `:idea_voice`, which returns a `transcribe_voice`
descriptor for `Supervisor#execute_transcribe_voice`. The supervisor
downloads the file through `getFile` + file download, sends the bytes to
`Hive::Bot::Transcriber`, and stores the transcript in
`IdeaDraftStore` with `origin: :voice` and phase
`:awaiting_transcript_confirm`. The operator can tap `Confirm`, tap
`Discard`, send corrected text, or send a replacement voice note. After
confirmation, the normal project picker appears; if the voice draft has
no attachments, choosing a project commits immediately without the
file-collection `Done` step. If transcription is disabled, the bot asks
for `/idea <text>` instead. If transcription fails after download, Hive
stages the original `.oga` as an idea attachment and asks for the idea
text, preserving the audio handoff.

Voice notes sent while an `/answer` conversation is active are audio
answers rather than new ideas. The router carries the active
conversation's project/slug/question into `transcribe_voice`; on a
successful transcript, the supervisor writes the transcript into the
current `brainstorm.md` answer slot through `BrainstormAnswerWriter`.
Reply-to reattach works the same way for voice as for typed answers.
No-speech, unsupported-language, disabled transcription, and transcription
failure paths reply with a retry/text fallback and do not create an idea
draft.

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
`/approve`, `/autofix`, `/details`, `/close` slash commands remain typeable
(and appear in the quick-actions menu as `<id|slug>`) for operators who
prefer typing or scripting.

### Dispatch acknowledgment on success

Commands dispatched as child processes (`hive new`, `hive approve`,
`hive run`, recovery sequences) now return a positive Telegram
confirmation on exit 0 instead of staying silent or surfacing raw
process text such as `exit 0`. `hive new` keeps the specific idea-capture
message because an idea lands in `1-inbox`, whose
`ready_to_brainstorm` notification is **suppressed entirely when the
project's daemon is enabled** (`suppress_ready_action?`, since the daemon
dispatches the transition itself) and, when the daemon is off, only fires
on a later dispatcher poll tick — never at tap time. Other commands use
human command-specific messages such as approved, run completed,
archived, finalized, status check completed, or accepted/rejected
findings. Detection keys on the verb at `argv[1]`, since
`ChildSupervisor#normalize_hive_bin` rewrites `argv[0]` to a resolved
binary path.

On bot start the supervisor calls Telegram's `setMyCommands` so the
blue quick-actions menu (shown when the operator taps the `/` icon in
the chat input) surfaces `/idea`, `/status`, `/queue`, `/answer`,
`/approve`, `/autofix`, `/details`, `/close`, `/done`, and `/help` with
human-readable descriptions. This is a one-shot idempotent RPC at
start — it is not re-issued on SIGHUP/config reload because the
command list does not change with config. A network failure during
registration is logged as `:send_failure` with
`source: "set_my_commands"` and does not block `poll_loop` from
starting. The command list and descriptions live in
`Hive::Bot::Supervisor::BOT_COMMANDS`. `/start` is handled separately by
the router for Telegram's first-contact update and is not part of that
registered quick-actions menu.

## Inline actions

Push notifications use callback data that routes to:

- Stage approvals: `Approve` dispatches `hive brainstorm|plan|develop|review|pr|archive <slug> --from <stage> --project <project> --json`.
- Brainstorm waits: `Answer in chat` starts the same `/answer` conversation.
- Review triage: `Accept all` / `Reject all` dispatch `hive accept-finding` or `hive reject-finding` with `--all`.
- Recovery markers: every `ERROR` and `REVIEW_ERROR` exposes `Autofix`, even when no diagnostic suggested action was recorded. It submits the cached row plus current observation token to the durable recovery coordinator, which re-resolves task identity and safety before any mutation and returns queued, cooldown, running, blocked, or terminal state. Every recoverable occurrence must bind `marker_id`; an old id-less row returns `recovery_migration_required` until `hive migrate` upgrades it once. `EXECUTE_STALE` remains manual-only and shows `Show details`, which renders the cached row summary plus manual-repair hint and any cached diagnostic; legacy `Clear and retry` buttons from older messages delegate directly to the current Autofix handler and therefore enter the same coordinator lifecycle. Callback data is generation-checked: every encoded stage, marker, and attr must still match the fresh row before the request is accepted.
- Legacy stage-directory warnings are text-only project-level alerts. They tell the operator to run `hive migrate <project_path>`, have no inline action, dedupe while the project remains legacy-dirty, and re-alert after the project reports clean then regresses.
- Idea project pickers use `idea_project:<project>:<token>`. Current drafts enter attachment collection instead of immediately spawning `hive new`; the follow-up keyboard emits `idea_done:<token>` and `idea_skip:<token>`, both of which finalize the current draft. `idea_project_new:<token>` clears the draft/picker token and replies that registering a new project from Telegram is out of MVP scope.
- Legacy Path-A buttons (`path_a_yes:` / `path_a_type:`) from messages sent before Codex draft-assist retirement do not start a draft flow; they reply with instructions to tap **Answer in chat** or send `/answer <id|slug>`. Retired `codex_write:` / `codex_edit:` / `codex_cancel:` data is unknown callback data.
- Evidence closure: `/close` resolves an active cached task row and creates the
  first compacted `closure_preview:` callback; the slash command itself does
  not verify evidence or mutate task state. `closure_preview:` decodes one
  bounded task/input payload,
  resolves the exact registered task, and calls `Hive::TaskClosure.preview`.
  A valid preview edits the message with normalized immutable facts plus one
  compacted `closure_confirm:` button. Confirmation rechecks the current chat
  allowlist, records `telegram:<from_id>` as operator, calls the shared
  confirm service, and edits the same message with the archived receipt.
  Non-allowlisted chats never reach dispatch; malformed/expired callbacks and
  stale evidence fail closed without invoking a workflow command.
- `Open laptop` is an explicit no-op reply for disagreements that do not fit the MVP button set.

## Config

The bot is global, not per-project:

```yaml
bot:
  enabled: false
  pairing_enabled: false
  chat_id_allowlist: [123456789]
  poll_interval_sec: 30
  long_poll_timeout_sec: 25
  notification_dedupe_window_sec: 300
  idea_draft_ttl_sec: 900
  idea_attachment_max_bytes: 20971520
  idea_attachment_max_count: 10
  transcription:
    enabled: true
    endpoint: https://api.openai.com/v1/audio/transcriptions
    model: whisper-1
    api_key_env: HIVE_WHISPER_API_KEY
    max_retries: 3
    retry_backoff_sec: 2
    timeout_sec: 120
    no_speech_threshold: 0.6
    supported_languages: [en, ru]
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
token makes `hive bot start` raise `Hive::ConfigError` (exit 78). An empty
allowlist also raises unless `bot.pairing_enabled: true`, in which case an
unknown DM `/start` receives a one-time pairing code and the owner approves it
with `hive pairing approve telegram <CODE>` (see [[commands/pairing]]). Unknown
non-`/start` chat IDs are still logged once per bot lifetime and ignored
silently.

The allowlist remains the bot's chat-auth boundary.

Voice transcription uses `bot.transcription.api_key_env` for the OpenAI
audio API key (default `HIVE_WHISPER_API_KEY`); the key is not persisted.
`supported_languages: []` disables the language filter. The same
`idea_attachment_max_bytes` cap gates the Telegram download before
transcription for both voice ideas and voice answers.

**Why OpenAI, not OpenRouter (plan Q1 / Risk 1):** the default
`endpoint`/`api_key_env` deliberately point at OpenAI's
`/v1/audio/transcriptions` (Whisper), not the project-standard OpenRouter.
OpenRouter is a chat/completions gateway and exposes **no
audio-transcription endpoint**, so the brainstorm's "Whisper" decision (A2)
requires an OpenAI-compatible audio API. The endpoint is config-overridable
to any OpenAI-compatible Whisper deployment (e.g. a self-hosted
`whisper.cpp` server), but it is not routed through OpenRouter. The
language gate normalizes Whisper's full-name `language` output ("english")
against ISO-code `supported_languages` ("en"), so either form works in
config.

`hive bot start` also loads `~/.config/hive/.env` (next to `config.yml`)
into `ENV` at startup so operators don't have to wire the token into a
shell rc file. Format is the conventional `KEY=value` per line; outer
single or double quotes are stripped; `#` starts a comment; existing env
vars take precedence (a manual `export HIVE_TELEGRAM_BOT_TOKEN=...`
always wins).

Example `~/.config/hive/.env`:

```
HIVE_TELEGRAM_BOT_TOKEN=123456789:AAAAa-BBBb-CCCC
HIVE_WHISPER_API_KEY=sk-...
```

The file is read once at `hive bot start` time; `hive bot reload`
re-reads `config.yml` but NOT `.env` (tokens are not reload-safe; restart
the bot after rotating).

## Structured log

`~/.local/state/hive/logs/bot.log` is one JSON document per line with schema
`hive-bot-log.v3` (`SCHEMA_VERSION = 3`). The event enum is closed in
`Hive::Bot::Logger::EVENTS`; unknown events raise at the call site. Every v3
line carries `level` (`debug`, `info`, `warn`, or `error`) and may carry
`category` for cross-cutting tags such as `noise`.

`v3` keeps event names stable and adds severity. Benign Telegram long-poll
transport timeouts still emit `poll_failure`, but at `debug`/`noise`; real poll
failures remain `warn`, and sustained outages also emit `poll_unhealthy` at
`warn`. `notification_skipped_dedupe` and `notification_skipped_backoff` are
debug/noise and are logged only on skip-state transitions. `v2` was introduced
when the Telegram "Codex draft-assist" feature was retired; `schemas/hive-bot-log.v1.json`
and `schemas/hive-bot-log.v2.json` are kept as-is for historical log lines.

The schema evolves additively: new event values may be appended to the
current version without changing `schema_version`. Breaking changes
(removing an event, renaming it, or changing the payload shape of an
existing event) require a new schema file alongside the prior one, with
bumped `$id` and a synchronized `schema_version` constant — exactly what
the v1 → v2 retirement did. Downstream consumers that pin on the `$id`
URL must therefore tolerate unknown event values; that's the read-side
compat invariant.
Events include `bot_started`, `poll_failure`, `poll_unhealthy`,
`update_received`, `notification_sent`, `dispatched_command`,
`command_completed`, `answer_written`, `reconnect_summary`, and `fatal`.

## Forward-tolerant `hive status` schema-version skew

`Hive::Bot::StatusWatcher` (the consumer behind `/status`) does NOT raise
on a `hive-status` `schema_version` mismatch — that would hard-crash
`/status` whenever the `hive` gem is bumped under a running bot. A newer
payload is parsed best-effort (additive-envelope contract) and logs a
`poll_schema_skew` skew warning; an older payload (stale binary on PATH) or a
newer payload that genuinely fails to parse returns an actionable
`failure(...)` result telling the operator to restart the bot or
update/reinstall the binary. The full classification (`:match` /
`:newer` / `:older`) and the matching daemon behavior live in
[[modules/daemon]] §"Forward-tolerant schema-version skew".

## Autostart

`hive bot install` gives the bot the same reboot-survivable per-user
service the daemon has (`hive daemon install`), built on the shared
`Hive::Commands::ServiceInstaller::Base` and command-side
`ResultPresenter`. Key differences from the daemon:

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
