---
timestamp: 2026-06-27T14:00:00Z
slug: answer-digest-review-fixes-pass2
tags: [bot, telegram, digest, daemon, schema]
---

## [2026-06-27T14:00:00Z] bot/daemon — answer-digest review-pass 2 hardening

**Action:** Applied the second 6-review fix-pass for the waiting-queue /
answer-digest feature (merged `origin/main` first to clear phantom reverts of
#598–#608 and pick up #608's markerless-plan reclassification).

- **Silent-drop observability:** `AnswerDigest#call` now builds/injects the bot
  logger *before* `WaitingRows.select` (it was built lazily only at send time,
  after selection). On the daemon/CLI path the per-row drop (`:poll_failure`)
  and button-build (`:status_button_failed`) logging now actually fires, so a
  silently-dropped human-blocking row leaves a trace — the feature's whole
  point. `/waiting` already had a real logger; only this path was blind.
- **Shared extractions:** `WaitingRows.row_project_path` and
  `WaitingRows.daemon_enabled_resolver(source:, logger:)` are now the single
  source for both `/waiting` (supervisor) and the digest, which only differ in
  the log `source:` string. The resolver memoizes the `ConfigError` result, so a
  broken project config loads/logs once per project, not once per waiting row.
- **`Result` type:** reconciled `dry_run` with `reason` (the `"dry_run"` reason
  must be a dry run; a real send is never one), added non-negativity /
  `button_count <= count` guards, promoted `tasks[]` to an
  `AnswerDigest::Task = Data.define(...)` value type (`Result` asserts
  `tasks.all?(Task)`), and froze the `tasks` collection.
- **JSON drift:** the empty waiting set now emits `message: null` even under
  `--dry-run` (derived from `result`, not the `@dry_run` ivar), matching the
  schema; the plain-text success line reports the true `count`, not the
  10-button cap.
- **Schema prose:** corrected `schemas/hive-answer-digest.v1.json` — a
  mid-delivery Telegram send error emits the `internal` ErrorPayload then exits
  non-zero (it does *not* go "without an envelope").
- **Cleanups:** collapsed the byte-identical `rescue Hive::Error` /
  `rescue StandardError` branches into one (`Hive::Error < StandardError`); made
  the dispatcher's `global_digest_action` a strict `case` matching its
  `global_digest_scheduler` sibling; added `# frozen_string_literal: true` to
  `waiting_rows.rb`; reconciled the `resolve` / `daemon_plan_pause?` drop
  comments with the logger-before-selection behavior.
- **Tests:** added the `--json` 11-row overflow contract (count 11, buttons 10,
  tasks 11), real-send stdout singular/plural, one-button-per-row nesting,
  digest-button↔RowActions byte-equality, empty+dry-run null message, the new
  `Result` guards, `tasks` frozen, the supervisor `status_keyboard` >10-button
  cap, scheduler `clamp_hour` boundaries, and daemon `enabled`/`hour`
  forwarding.

**Verification:** focused unit tests for waiting rows, supervisor, answer-digest
command, daemon dispatcher/scheduler, and daemon command; schema JSON parse;
RuboCop over the touched Ruby and test files.
