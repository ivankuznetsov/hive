---
title: Hive::Bot
type: module
source: lib/hive/bot/
created: 2026-05-14
updated: 2026-06-15
tags: [bot, telegram, module, mobile]
---

**TLDR**: `Hive::Bot::*` is the Telegram operator surface for daemon
human-input gates. The supervisor has three loops: Telegram long-poll,
`hive status --json` notification polling, and child reaping. Pure
routing/parsing logic is split away from Telegram, filesystem,
and subprocess I/O. (The earlier "Codex draft-assist" brainstorm flow —
where Path A spawned Codex to draft answers — has been retired; brainstorm
answering is now deterministic Q-by-Q.)

## Module map

| Module | File | Purpose |
|--------|------|---------|
| `Supervisor` | `lib/hive/bot/supervisor.rb` | Long-running loop. Polls Telegram, runs status ticks, reaps child commands, handles TERM/INT/HUP, writes last-seen update IDs. |
| `Telegram` | `lib/hive/bot/telegram.rb` | Thin `telegram-bot-ruby` wrapper for `getUpdates`, `sendMessage`, message splitting, markdown escaping, typed `Update` records, media/voice metadata extraction, `getFile`, and file download. |
| `Format` | `lib/hive/bot/format.rb` | Telegram-safe HTML helpers for status/queue and notification messages: text/attribute escaping, control-character stripping, http(s) URL validation, and `pr_url` → clickable `#<number>` links via [[modules/pr]]. |
| `Router` | `lib/hive/bot/router.rb` | Closed-enum intent classifier and pure dispatch into slash/callback/free-text handlers. Performs allowlist auth before any handler sees an update. The first-contact `/start` command has its own `:slash_start` intent so a newly connected Telegram chat receives a welcome instead of the unknown-command hint. Idea capture includes media updates, voice-note transcription/edit intents, awaiting-text drafts, project-pick callbacks, transcript confirm/discard callbacks, and Done/Skip callbacks. Voice notes sent during an active or reattached `/answer` conversation route to the transcription action with answer context instead of being treated as blank free text. Legacy `path_a_yes:` / `path_a_type:` callbacks classify only to retirement replies; retired `codex_*` callback data has no live intent. |
| `Handlers::*` | `lib/hive/bot/handlers/` | Slash command, callback, and free-text logic returning descriptors; no direct Telegram I/O. `SlashHandlers#start` is a pure reply descriptor with a "Connected" welcome plus `/status`, `/idea`, and `/help` next steps. |
| `IdeaDraftStore` | `lib/hive/bot/idea_draft_store.rb` | In-memory per-chat `/idea` draft state with TTL, project/text/attachment metadata, voice-origin and transcript-confirm phases, monotonic attachment counters, temp staging-dir allocation, and cleanup on clear/prune. |
| `IdeaAttachmentPolicy` | `lib/hive/bot/idea_attachment_policy.rb` | Pure classifier for Telegram photo/document attachments. Allows jpg/jpeg/png/webp/gif/pdf/txt/md/docx, enforces count/byte caps, and normalizes extensions through `Hive::Tui::ComposerStaging`. |
| `Transcriber` | `lib/hive/bot/transcriber.rb` | OpenAI-compatible audio transcription client for Telegram voice notes used by idea capture and audio answers. Posts `multipart/form-data` to `bot.transcription.endpoint` with `model`, retries transient failures, maps empty/high no-speech-prob results to `:no_speech`, applies `supported_languages`, and logs failures through the bot logger. |
| `StatusWatcher` | `lib/hive/bot/status_watcher.rb` | Runs `hive status --json`, validates the envelope, returns typed task rows carrying slug/id/display_name/`pr_url` plus project-level legacy-stage warnings. |
| `NotificationDispatcher` | `lib/hive/bot/notification_dispatcher.rb` | Sends newly-entered waiting/recovery rows, daemon-disabled ready approvals, and project-level legacy-stage warnings through a persistent alert lifecycle store. Ready notifications are suppressed when the daemon is enabled for that project; recovery rows get one confirmation when they leave the active set, same-task recovery fingerprint changes are treated as superseded rather than recovered, and unchanged recovery rows get one reminder. **`needs_input` (brainstorm/review "waiting") pushes are suppressed for a project+slug with an active answer conversation** (`ConversationStore#active_for_slug?(slug, project:)`, injected): the operator is already answering, so a row that briefly flaps out of and back into `WAITING` (e.g. a mid-answer daemon resume) won't re-fire the "questions waiting" push. Suppression is lenient when either side lacks a project, but two fully resolved different projects sharing a slug do not cross-suppress. The first alert still fires (no conversation exists until the operator taps **Answer in chat**), error/recovery alerts are never gated this way, and a TTL-expired/abandoned conversation stops suppressing (re-engaging the operator). Suppressed rows are logged as `notification_skipped_active_conversation` and never enter the alert store, so ending the conversation can re-alert if the task is still waiting. |
| `AlertStore` | `lib/hive/bot/alert_store.rb` | JSON sidecar for alert fingerprints, first-seen timestamps, reminder timestamps, and row snapshots. Corrupt files are renamed aside so the bot keeps running. |
| `NotificationBuilders` | `lib/hive/bot/notification_builders.rb` | Marker/action-specific text and inline keyboards. Recovery alerts are human-readable; Autofix is exposed only when the diagnostic `suggested_next_action.kind` is `retry`, while manual-only states show details actions. `details_reply(row)` is the shared Show-details renderer for inline callbacks, `/details`, and status row details: it always includes the row summary and next-step hint, appends cached diagnostic summary/detail when present, and caps replies to Telegram's 4096-character limit. All three render sites wrap the call in a soft-degrade rescue (`render_details_reply` in the handlers, an inline rescue in `Supervisor#render_details`): a render-time fault logs `details_render_failed` and replies "Status lookup failed — try again in a moment." rather than escaping past the already-ack'd callback / poll loop and leaving the operator with no reply. The slash `resolve_status_row` degrade now also logs `status_lookup_failed`. The `ready_for_review` approval push appends a clickable PR link when `row.pr_url` is valid. Fingerprints include project, slug, stage, marker, and marker attrs, deliberately excluding `pr_url` and rendered text. |
| `BrainstormParser` | `lib/hive/bot/brainstorm_parser.rb` | **Back-compat alias for `Hive::BrainstormParser`** (`lib/hive/brainstorm_parser.rb`) — the pure parser moved to the top-level namespace so the daemon can share it for the answers-pending gate (see [[modules/daemon]] §"Brainstorm answers-pending gate"). Parses `## Round`, `### Q<N>.`, and `### A<N>.` blocks. **Lenient A-header**: accepts the first A-section under each Q as that Q's answer slot regardless of A-number, so a brainstorm-agent off-by-one (e.g. `### A2.` after `### Q1.`) doesn't strand the operator. `parse` is total — invalid UTF-8 and a torn concurrent read degrade rather than raise. Also exposes canonical heading helpers (`question_header(n)`, `answer_header(n)`) so writer / supervisor / future renderers share one format source of truth. |
| `BrainstormAnswerWriter` | `lib/hive/bot/brainstorm_answer_writer.rb` | Locked, first-write-wins insertion into the next answer block, with atomic rewrite. Slot location is **Q-context-aware**: walks forward from the parser-identified target Q's line, returning the first empty A-section before the next block boundary. When Q{n} is present and unanswered but has **no `### A` slot at all**, the writer **creates** the slot at the end of the Q-block (before the next Q/Round/marker boundary, via the parser's canonical `answer_header`) and writes the answer there — so a brainstorm agent that emitted a question without an answer block no longer dead-ends the operator (issue #269; previously `:answer_slot_missing`, which with the daemon's answers-pending gate held the task indefinitely). `:answer_slot_missing` remains only as a defensive fallback when the Q line can't be located. `Errno::ENOENT` on the underlying file is mapped to `:question_not_found` (not lock contention). |
| `ConversationStore` | `lib/hive/bot/conversation_store.rb` | In-memory per-chat active answer state with TTL. No sidecar file; `brainstorm.md` stays canonical. State now carries only `chat_id`, `project`, `slug`, `question_n`, `mode`, and `updated_at`; the retired Codex draft-assist fields (`history`, `draft`, `awaiting_confirm`) and `pending_confirm_count` API are gone. All `@states` reads/writes are mutex-guarded because the Telegram poll thread mutates conversations while the status-poll thread calls `active_for_slug?` and prunes. `active_for_slug?(slug, project: nil)` is prune-aware and returns true when any chat has a non-expired answer conversation for that slug. Project scoping is lenient: two fully resolved different projects do not cross-suppress, but an unscoped/project-less side still suppresses to avoid reintroducing duplicate waiting alerts. `NotificationDispatcher` uses this to avoid duplicate proactive waiting pushes while the operator is already answering. |
| `ChildSupervisor` | `lib/hive/bot/child_supervisor.rb` | Spawns child `hive ...` commands with `pgroup: true`, writes per-dispatch logs, reaps with `Process.wait2(-1, WNOHANG)`. After plan 2026-05-28-002 the bot only reaches this path for **non-queue-routable** verbs (`hive status --diagnose --write --force` for Refresh diagnostic, `hive new` for the idea picker, `hive approve` for the /approve slash command, `hive accept-finding` / `hive reject-finding` for findings replies). State-mutating workflow verbs are written to the daemon's dispatch-request queue instead — see `DispatchRequestWriter` below. |
| `DispatchRequestWriter` | `lib/hive/bot/dispatch_request_writer.rb` | Producer-only client of the daemon's dispatch-request queue. Atomic tmp+rename JSON write into `<state_home>/dispatch_requests/`. Argv validated against `Hive::Daemon::DispatchRequestQueue::ALLOWED_VERBS` at the call site too, so a typo in a slash handler raises locally rather than silently writing a request the daemon would discard. Returns a `request_id` the daemon echoes back in its `dispatch_request_*` events. |
| `Logger` | `lib/hive/bot/logger.rb` | JSON-line structured logger with size rotation and closed event enum. `SCHEMA_VERSION` is now `2`: `hive-bot-log.v2` (`schemas/hive-bot-log.v2.json`) drops the retired `codex_spawned` / `codex_succeeded` / `codex_failed` events; `v1` is kept as-is for historical log lines. `notification_skipped_active_conversation` remains part of the schema, so suppress-while-answering decisions have the same audit trail shape as other notification skip paths. |
| `Commands::Bot` | `lib/hive/commands/bot.rb` | Thor command surface and PID-file lifecycle. |

## Wiring

```
hive bot start
  └─ Hive::Commands::Bot (daemonizes unless --foreground)
       ├─ validates global bot config + HIVE_TELEGRAM_BOT_TOKEN
       ├─ writes ~/.local/state/hive/.bot.pid
       └─ Hive::Bot::Supervisor.run_forever
            ├─ poll loop: Telegram.getUpdates → Router → handler descriptors
            ├─ status loop: hive status --json → NotificationDispatcher
            └─ reaper loop: ChildSupervisor.reap_all → Telegram reply
```

Task notifications use `NotificationBuilders.display_title(row)`: `#<id> <display_name>` when both are present, plain `display_name` when only the name is available, and `TitleFormatter.title_from_slug(slug)` as the legacy fallback. Human text and `/status`/queue/detail rows use that title, but callback data and slash-command arguments remain slug-based.

`Router::Result` is the handoff API between pure routing and side
effects. The normal command actions remain `reply`,
`dispatch_then_reply`, `dispatch_commands`, `start_answer`, and
`write_answer_then_reply`. The idea-attachment flow adds
`stage_attachment`, `transcribe_voice`, and `commit_idea`: attachments
download one Telegram file into draft staging; voice transcription
downloads a Telegram voice file, runs `Hive::Bot::Transcriber`, and
either stores/edits an idea transcript or writes an audio answer through
the normal brainstorm answer path; commit calls `Hive::Commands::New`
in-process to create the inbox task. There is no `start_codex` /
`confirm_codex_draft` result action; Path A/B remains only as an answer
mode value for compatibility, and both modes use `write_answer_then_reply`.

Recovery push notifications intentionally hide marker attrs, exception
classes, phase names, diagnostic summaries, and diagnostic artifact
paths. The operator-facing message is `Stage stuck` plus one
plain-language cause sentence. `Autofix` is shown only for retryable
diagnostics; manual-only states such as `EXECUTE_STALE` and
fix-tampered review errors show `Open laptop` / `Show details` instead.
Autofix callbacks carry a marker attribute such as `pass=2` when one is
available, so stale Telegram buttons cannot clear a newer marker. For
`ERROR` rows they prefer the generated `marker_id` and fall back to
observed `reason`/`exit_code` attrs for legacy markers. The dispatcher
clears the persisted alert entry for that task before
spawning the retry sequence. `/status [project]` and `/queue` are explicit
pull surfaces and render actionable rows as `#id Title… — #561 — Stage`
or `#id Title… — — — Stage`. They use Telegram HTML parse mode so valid
`pr_url` values become clickable `#<number>` links; all dynamic title,
stage, and legacy-warning text is escaped through `Hive::Bot::Format`.
Inline callback buttons remain slug-based and unaffected by parse mode.

The open-PR completion push is the existing `ready_for_review`
stage-approval notification, not a new notification type. When that row
has a valid `pr_url`, `NotificationBuilders#stage_approval` appends
`PR: #<number>` as a Telegram HTML link and sets the notification
`parse_mode`; `NotificationDispatcher#send_notification` forwards it.
Because the alert fingerprint still hashes only project, slug, stage,
marker, and marker attrs, adding or rendering `pr_url` does not re-send an
already-seen ready-for-review alert.

Legacy stage-directory warnings are proactive as project-level notifications. `StatusWatcher` converts non-empty `legacy_stage_dirs` project payloads into synthetic notification inputs, `Supervisor#status_tick` feeds them through the same `NotificationDispatcher` as task rows, and `NotificationBuilders` renders a message like `Project P has N tasks hidden in legacy stage dirs (...) - run hive migrate <project_path>`. The same warning appears in `/status` and `/queue` replies. The alert-store fingerprint is project-level rather than count-level, so the warning dedupes while the project remains legacy-dirty, drops when the project returns clean, and alerts again on a later clean-to-legacy transition. Fresh alert-store seeding still suppresses historical task backlog, but legacy-stage warnings alert immediately because first bot startup after an upgrade is when operators need the migration prompt.

### Forward schema-version skew on `/status`

`StatusWatcher#fetch` is forward-tolerant of a newer `hive-status`
`schema_version` than this long-running bot was built for — the shared
mechanism is documented under [[modules/daemon]] § *Forward-tolerant
schema-version skew*. Bot-specific behaviour (fix-forward on #416):

- On a `:newer` best-effort SUCCESS the `Result` carries a non-fatal
  `warning`. `Supervisor#execute_dispatch` prepends a one-line plain-text
  banner ("⚠️ hive status: running on a newer schema than this bot
  understands; data may be incomplete — restart the bot.") to the
  `/status` (and `/queue`) reply, so the Telegram operator sees the
  advisory rather than a normal-looking status with a silent log line.
- The success-path skew advisory is logged under the **distinct**
  `:poll_schema_skew` event (not the overloaded `:poll_failure`), so it
  isn't conflated with real fetch failures. `:poll_schema_skew` is in
  `Hive::Bot::Logger::EVENTS` and the `hive-bot-log.v2` schema enum
  (additive append — no schema-version bump).
- `validate_envelope!` (shape / `ok=false`) runs OUTSIDE the best-effort
  extraction rescue: a `:newer` envelope that ALSO has `ok=false` surfaces
  its real `envelope ok=false: <reason>`, never the skew hint. A throw
  inside extraction on a `:newer` doc degrades to the restart message but
  **preserves the underlying exception** in the surfaced `error` (`…
  (underlying error: <Class>: <msg>)`) AND logs it under
  `:poll_schema_skew` (class + message + first backtrace lines) so a real
  extraction defect stays recoverable.

## Trust boundary

The bot does not move task folders or invent approval policy. State
mutations go through existing `hive` commands (`new`, workflow verbs,
`markers clear`, `accept-finding`, `reject-finding`, `run`) except for
two narrow in-process paths. Brainstorm answer insertion is deliberately narrow:
`BrainstormAnswerWriter.append!` holds `Hive::Lock.with_task_lock`,
re-parses the file under the lock, refuses non-empty answer slots, and
inserts the literal answer text. Two devices racing the same question
therefore produce one answer and one "already answered" reply, not a
merged or overwritten block.

Idea capture with attachments and voice notes is the second in-process
path. The router stores draft text/project/phase in `IdeaDraftStore`;
`Supervisor` stages each accepted Telegram attachment in a process-owned
temp directory, then `commit_idea` builds a markdown body that embeds
images as `![](assets/<name>)` and links non-images as
`[name](assets/<name>)`. Voice notes are transcribed before project
selection: successful transcripts enter `:awaiting_transcript_confirm`,
where the operator can confirm, discard, send corrected text, or send a
replacement voice note. A confirmed voice draft with no attachments
commits as plain `idea.md` immediately after project selection. If
transcription fails after the file is downloaded, the `.oga` is staged as
`voice-N.oga` and the draft falls back to awaiting idea text. The final
create operation is `Hive::Commands::New#call!`, so slug validation,
`assets/` copying, rollback-on-write-failure, and `hive/state` commit
behavior remain shared with the CLI/TUI capture surface. Draft cleanup
removes the staging directory. A bare voice note is refused while a
non-voice idea draft is open, preserving the existing typed/media draft
instead of clearing it through the voice transcription path.

Audio answers reuse the same download/transcription action with
`purpose: :answer`. The router attaches the active `ConversationStore`
state (or a reply-to reattach target) to the result, and the supervisor
feeds a successful transcript into `execute_answer_write`. That means the
same task lock, first-write-wins behavior, auto-advance reply, and
all-answered auto-dispatch semantics apply to spoken answers as to typed
answers; failed/no-speech/unsupported-language transcripts reply without
creating or mutating an idea draft.

## Single-dispatcher invariant (plan 2026-05-28-002)

The bot is producer-only for state-mutating workflow verbs. When
`Supervisor#execute_dispatch` sees an argv whose verb is in
`Hive::Daemon::DispatchRequestQueue::ALLOWED_VERBS`
(`run develop brainstorm plan review open-pr artifacts finalize
archive markers`), the dispatch is rewritten to
`DispatchRequestWriter.write!` and a `:dispatched_command via=queue
request_id=…` event is logged. The daemon picks up the request
on its next tick.

For multi-command sequences (`dispatch_command_sequence`, used by
Autofix's `markers clear` + retry-verb pair), the bot writes only the
first queue-routable command and persists later commands as a hidden
sequence sidecar keyed by that request id. The daemon promotes the next
command only when the current request exits 0; a non-zero or killed
clear command discards the sidecar so the retry cannot run against a
still-set recovery marker.

Audit (CI-enforced post-merge):

```
rg -n 'Process.spawn|spawn!|system\(' lib/hive/bot/
# Only match: lib/hive/bot/child_supervisor.rb's Process.spawn,
# which is now reached only by the read-only / non-queue-routable
# verbs above. No matches for ALLOWED_VERBS.
```

See [[modules/daemon]] §"Single-dispatcher" and [[architecture]]
§"Dispatch flow" for the daemon side of the contract.

## Dispatch result notices

After the single-dispatcher refactor, the daemon is the process that
spawns queue-routed bot requests, but it has no Telegram client. When a
bot-originated daemon child completes, `Hive::Daemon::Dispatcher`
writes a `hive-dispatch-result` notice under
`<state_home>/dispatch_results/`. `Supervisor#reaper_loop` calls
`drain_dispatch_results`, which relays those notices back to the
originating chat. Exit 0 is rendered as a positive command-specific
confirmation (for example `Run completed for <project>/<slug>.` or
`Archived <project>/<slug>.`); non-zero exits and nil signal/timeout
exits still render as
`<slug>: hive <verb> failed (exit N)` or `killed (signal/timeout)`.
For queue-routed recovery sequences, the daemon suppresses the
intermediate success notice for the marker-clear step when it promotes
the retry command, so the operator sees the final result rather than two
success pings.
Before relaying, `drain_dispatch_results` re-checks each notice's
`chat_id` against `chat_id_allowlist` (defense-in-depth, #263): the
chat_id round-trips from the on-disk request file through the daemon with
no re-validation, so a chat removed from the allowlist while a request
was in flight — or a notice forged in the 0700 dir — is dropped +
removed (logging `:dispatch_result_rejected_unauthorized`) instead of
relayed, mirroring the allowlist filtering on the nudge/reconnect paths.

The consumer side is deliberately retry-safe. `Supervisor` removes a
notice only after `safe_send_message` returns a sent result, so a
Telegram outage leaves the file on disk for the next reaper tick.
Malformed notices are removed quietly. Notices older than
`Hive::Daemon::DispatchResultQueue::EXPIRY_SEC` (1h) are stale and are
dropped without relaying; the daemon also prunes them each tick as a
backstop when no bot is running. To avoid reconnect floods,
`DISPATCH_RESULT_SEND_CAP` limits individual result messages per drain
and collapses the overflow into one per-chat summary, removing the
overflow files only after the summary sends.

## Reload Behavior

`Supervisor#reload_config_if_requested` reloads the global bot config,
rebuilds the router, notification dispatcher, and voice transcriber, and
updates the shared conversation TTL. Rebuilding the transcriber is
required because `Hive::Bot::Transcriber` snapshots
`bot.transcription.*` settings such as endpoint, model, retry/backoff,
timeout, no-speech threshold, supported languages, and API-key env name
at construction time; `hive bot reload` must apply those settings without
a full bot restart.

## Eval harness

`test/eval/` exercises this module through the same supervisor entrypoints production uses, with only Telegram and child-process I/O replaced by in-process fakes. The harness classifies outbound messages into the eval contract reasons (`agent_blocked_question`, `status_response`, `task_finished`, `fatal_error`) from observable status rows, handler intents, and child exits. That mapping stays test-only; production bot payloads are unchanged. The live Telegram wrapper `test/e2e/tg/run_idea_e2e.sh` remains opt-in; in `TG_IDEA_MODE=voice` it now exercises both a new audio idea and a seeded audio `/answer` path with the checked-in voice fixture when Telegram/OpenAI credentials are present.

## Backlinks

- [[commands/bot]]
- [[commands/status]] · [[modules/task_action]]
- [[modules/daemon]]
- [[decisions]] (ADR-026)
