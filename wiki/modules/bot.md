---
title: Hive::Bot
type: module
source: lib/hive/bot/
created: 2026-05-14
updated: 2026-06-05
tags: [bot, telegram, module, mobile]
---

**TLDR**: `Hive::Bot::*` is the Telegram operator surface for daemon
human-input gates. The supervisor has three loops: Telegram long-poll,
`hive status --json` notification polling, and child reaping. Pure
routing/parsing logic is split away from Telegram, filesystem, Codex,
and subprocess I/O.

## Module map

| Module | File | Purpose |
|--------|------|---------|
| `Supervisor` | `lib/hive/bot/supervisor.rb` | Long-running loop. Polls Telegram, runs status ticks, reaps child commands, handles TERM/INT/HUP, writes last-seen update IDs. |
| `Telegram` | `lib/hive/bot/telegram.rb` | Thin `telegram-bot-ruby` wrapper for `getUpdates`, `sendMessage`, message splitting, markdown escaping, typed `Update` records, media metadata extraction, `getFile`, and file download. |
| `Router` | `lib/hive/bot/router.rb` | Closed-enum intent classifier and pure dispatch into slash/callback/free-text handlers. Performs allowlist auth before any handler sees an update. Idea capture includes media updates, awaiting-text drafts, project-pick callbacks, and Done/Skip callbacks. |
| `Handlers::*` | `lib/hive/bot/handlers/` | Slash command, callback, and free-text logic returning descriptors; no direct Telegram I/O. |
| `IdeaDraftStore` | `lib/hive/bot/idea_draft_store.rb` | In-memory per-chat `/idea` draft state with TTL, project/text/attachment metadata, monotonic attachment counters, temp staging-dir allocation, and cleanup on clear/prune. |
| `IdeaAttachmentPolicy` | `lib/hive/bot/idea_attachment_policy.rb` | Pure classifier for Telegram photo/document attachments. Allows jpg/jpeg/png/webp/gif/pdf/txt/md/docx, enforces count/byte caps, and normalizes extensions through `Hive::Tui::ComposerStaging`. |
| `StatusWatcher` | `lib/hive/bot/status_watcher.rb` | Runs `hive status --json`, validates the envelope, returns typed task rows plus project-level legacy-stage warnings. |
| `NotificationDispatcher` | `lib/hive/bot/notification_dispatcher.rb` | Sends newly-entered waiting/recovery rows, daemon-disabled ready approvals, and project-level legacy-stage warnings through a persistent alert lifecycle store. Ready notifications are suppressed when the daemon is enabled for that project; recovery rows get one confirmation when they leave the active set, same-task recovery fingerprint changes are treated as superseded rather than recovered, and unchanged recovery rows get one reminder. **`needs_input` (brainstorm/review "waiting") pushes are suppressed for a project+slug with an active answer conversation** (`ConversationStore#active_for_slug?(slug, project:)`, injected): the operator is already answering, so a row that briefly flaps out of and back into `WAITING` (e.g. a mid-answer daemon resume) won't re-fire the "questions waiting" push. Suppression is lenient when either side lacks a project, but two fully resolved different projects sharing a slug do not cross-suppress. The first alert still fires (no conversation exists until the operator taps **Answer in chat**), error/recovery alerts are never gated this way, and a TTL-expired/abandoned conversation stops suppressing (re-engaging the operator). Suppressed rows are logged as `notification_skipped_active_conversation` and never enter the alert store, so ending the conversation can re-alert if the task is still waiting. |
| `AlertStore` | `lib/hive/bot/alert_store.rb` | JSON sidecar for alert fingerprints, first-seen timestamps, reminder timestamps, and row snapshots. Corrupt files are renamed aside so the bot keeps running. |
| `NotificationBuilders` | `lib/hive/bot/notification_builders.rb` | Marker/action-specific text and inline keyboards. Recovery alerts are human-readable; Autofix is exposed only when the diagnostic `suggested_next_action.kind` is `retry`, while manual-only states show laptop/details actions. Fingerprints include project, slug, stage, marker, and marker attrs. |
| `BrainstormParser` | `lib/hive/bot/brainstorm_parser.rb` | **Back-compat alias for `Hive::BrainstormParser`** (`lib/hive/brainstorm_parser.rb`) — the pure parser moved to the top-level namespace so the daemon can share it for the answers-pending gate (see [[modules/daemon]] §"Brainstorm answers-pending gate"). Parses `## Round`, `### Q<N>.`, and `### A<N>.` blocks. **Lenient A-header**: accepts the first A-section under each Q as that Q's answer slot regardless of A-number, so a brainstorm-agent off-by-one (e.g. `### A2.` after `### Q1.`) doesn't strand the operator. `parse` is total — invalid UTF-8 and a torn concurrent read degrade rather than raise. Also exposes canonical heading helpers (`question_header(n)`, `answer_header(n)`) so writer / supervisor / future renderers share one format source of truth. |
| `BrainstormAnswerWriter` | `lib/hive/bot/brainstorm_answer_writer.rb` | Locked, first-write-wins insertion into the next answer block, with atomic rewrite. Slot location is **Q-context-aware**: walks forward from the parser-identified target Q's line, returning the first empty A-section before the next block boundary. When Q{n} is present and unanswered but has **no `### A` slot at all**, the writer **creates** the slot at the end of the Q-block (before the next Q/Round/marker boundary, via the parser's canonical `answer_header`) and writes the answer there — so a brainstorm agent that emitted a question without an answer block no longer dead-ends the operator (issue #269; previously `:answer_slot_missing`, which with the daemon's answers-pending gate held the task indefinitely). `:answer_slot_missing` remains only as a defensive fallback when the Q line can't be located. `Errno::ENOENT` on the underlying file is mapped to `:question_not_found` (not lock contention). |
| `ConversationStore` | `lib/hive/bot/conversation_store.rb` | In-memory per-chat active answer/Codex state with TTL. No sidecar file; `brainstorm.md` stays canonical. All `@states` reads/writes are mutex-guarded because the Telegram poll thread mutates conversations while the status-poll thread calls `active_for_slug?` and prunes. `active_for_slug?(slug, project: nil)` is prune-aware and returns true when any chat has a non-expired answer conversation for that slug. Project scoping is lenient: two fully resolved different projects do not cross-suppress, but an unscoped/project-less side still suppresses to avoid reintroducing duplicate waiting alerts. `NotificationDispatcher` uses this to avoid duplicate proactive waiting pushes while the operator is already answering. |
| `CodexConversation` | `lib/hive/bot/codex_conversation.rb` | Short-lived Path A Codex spawn wrapper. Parses `BOT_REPLY`, `BOT_DRAFT`, and `BOT_ERROR` lines. |
| `ChildSupervisor` | `lib/hive/bot/child_supervisor.rb` | Spawns child `hive ...` commands with `pgroup: true`, writes per-dispatch logs, reaps with `Process.wait2(-1, WNOHANG)`. After plan 2026-05-28-002 the bot only reaches this path for **non-queue-routable** verbs (read-only `hive status --diagnose` for /details, `hive new` for the idea picker, `hive approve` for the /approve slash command, `hive accept-finding` / `hive reject-finding` for findings replies). State-mutating workflow verbs are written to the daemon's dispatch-request queue instead — see `DispatchRequestWriter` below. |
| `DispatchRequestWriter` | `lib/hive/bot/dispatch_request_writer.rb` | Producer-only client of the daemon's dispatch-request queue. Atomic tmp+rename JSON write into `<state_home>/dispatch_requests/`. Argv validated against `Hive::Daemon::DispatchRequestQueue::ALLOWED_VERBS` at the call site too, so a typo in a slash handler raises locally rather than silently writing a request the daemon would discard. Returns a `request_id` the daemon echoes back in its `dispatch_request_*` events. |
| `Logger` | `lib/hive/bot/logger.rb` | JSON-line structured logger with size rotation and closed event enum. `notification_skipped_active_conversation` is part of `hive-bot-log.v1`, so suppress-while-answering decisions have the same audit trail shape as other notification skip paths. |
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

`Router::Result` is the handoff API between pure routing and side
effects. The normal command actions remain `reply`,
`dispatch_then_reply`, `dispatch_commands`, `start_answer`, and
`write_answer_then_reply`. The idea-attachment flow adds
`stage_attachment` and `commit_idea`: the first downloads one Telegram
file into draft staging, and the second calls `Hive::Commands::New`
in-process to create the inbox task.

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
spawning the retry sequence. `/status [project]` is an explicit pull
surface and renders actionable rows as `Title… — Stage` without inline
buttons.

Legacy stage-directory warnings are proactive as project-level notifications. `StatusWatcher` converts non-empty `legacy_stage_dirs` project payloads into synthetic notification inputs, `Supervisor#status_tick` feeds them through the same `NotificationDispatcher` as task rows, and `NotificationBuilders` renders a message like `Project P has N tasks hidden in legacy stage dirs (...) - run hive migrate <project_path>`. The same warning appears in `/status` and `/queue` replies. The alert-store fingerprint is project-level rather than count-level, so the warning dedupes while the project remains legacy-dirty, drops when the project returns clean, and alerts again on a later clean-to-legacy transition. Fresh alert-store seeding still suppresses historical task backlog, but legacy-stage warnings alert immediately because first bot startup after an upgrade is when operators need the migration prompt.

## Trust boundary

The bot does not move task folders or invent approval policy. State
mutations go through existing `hive` commands (`new`, workflow verbs,
`markers clear`, `accept-finding`, `reject-finding`, `run`) except for
two narrow in-process paths. Brainstorm answer insertion is deliberately narrow:
`BrainstormAnswerWriter.append!` holds `Hive::Lock.with_task_lock`,
re-parses the file under the lock, refuses non-empty answer slots, and
inserts the literal confirmed text. Two devices racing the same question
therefore produce one answer and one "already answered" reply, not a
merged or overwritten block.

Idea capture with attachments is the second in-process path. The router
stores draft text/project/phase in `IdeaDraftStore`; `Supervisor` stages
each accepted Telegram attachment in a process-owned temp directory, then
`commit_idea` builds a markdown body that embeds images as
`![](assets/<name>)` and links non-images as `[name](assets/<name>)`.
The final create operation is `Hive::Commands::New#call!`, so slug
validation, `assets/` copying, rollback-on-write-failure, and
`hive/state` commit behavior remain shared with the CLI/TUI capture
surface. Draft cleanup removes the staging directory.

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

## Dispatch failure notices

After the single-dispatcher refactor, the daemon is the process that
spawns queue-routed bot requests, but it has no Telegram client. When a
bot-originated daemon child exits non-zero or with a nil exit status
(signal/timeout), `Hive::Daemon::Dispatcher` writes a
`hive-dispatch-result` notice under `<state_home>/dispatch_results/`.
`Supervisor#reaper_loop` calls `drain_dispatch_results`, which relays
those notices back to the originating chat as
`<slug>: hive <verb> failed (exit N)` or `killed (signal/timeout)`.
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
`DISPATCH_RESULT_SEND_CAP` limits individual failure messages per drain
and collapses the overflow into one per-chat summary, removing the
overflow files only after the summary sends.

## Eval harness

`test/eval/` exercises this module through the same supervisor entrypoints production uses, with only Telegram and child-process I/O replaced by in-process fakes. The harness classifies outbound messages into the eval contract reasons (`agent_blocked_question`, `status_response`, `task_finished`, `fatal_error`) from observable status rows, handler intents, and child exits. That mapping stays test-only; production bot payloads are unchanged.

## Backlinks

- [[commands/bot]]
- [[commands/status]] · [[modules/task_action]]
- [[modules/daemon]]
- [[decisions]] (ADR-026)
