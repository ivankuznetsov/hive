---
timestamp: 2026-06-28T12:00:00Z
slug: answer-digest-review-fixes-pass3
tags: [bot, telegram, digest, daemon, schema, reliability]
---

## [2026-06-28T12:00:00Z] bot/daemon — answer-digest review-pass 3 hardening

**Action:** Applied the third 6-review fix-pass for the waiting-queue /
answer-digest feature (see [[commands/answer-digest]]).

- **Scheduler duplicate-send loop:** `AnswerDigestScheduler#complete` now
  advances the cursor BEFORE clearing the failure backoff, and (re-)engages the
  backoff if the `write_state` rename fails (ENOSPC/EROFS). Previously a write
  fault after a successful send left the day owed with no backoff → the next
  tick re-fired and re-sent the same daily digest unbounded. `DigestScheduler`
  carries the identical pre-existing defect; left unchanged per the plan's
  "byte-for-byte mirror" scoping, noted here as a follow-up.
- **All-or-nothing send → per-row resilience:** `render_digest` and
  `task_descriptor` are now per-row guarded (parity with
  `WaitingRows.select`/`button_for`) — a row that raises while rendering drops
  its line / degrades to a placeholder descriptor (logged `:poll_failure`)
  instead of failing the single Telegram send. Oversized titles are
  length-bounded (digest line + button text) so a multi-KB task name can't
  trip Telegram's 400. The `Result` is now built/validated BEFORE the
  irreversible send, and `emit`/`emit_error_envelope` carry the EPIPE/JSON
  guard sibling `--json` commands have, so no post-delivery fault can re-raise
  into a duplicate re-send.
- **Exit-code contract reconciled:** `StatusUnavailableError` now inherits
  `UnavailableError` (exit 69); an untyped fault is wrapped in
  `Hive::InternalError` (exit 70, EnvelopeEmitter convention) so `internal`'s
  documented exit 70 is reachable; a malformed programmatic invocation raises a
  new command-local `UsageError` (exit 64) instead of `ConfigError` (78). Schema
  enum + descriptions, `cli.rb` exit-code block, and the wiki error table all
  updated to agree.
- **Drift guard made bidirectional:** the `NEEDS_INPUT_KINDS` load-time guard is
  now a partition-equality check against `RowActions::KINDS` (via a new
  `NON_NEEDS_INPUT_KINDS`), so a newly-ADDED upstream needs-input kind not
  mirrored in fails loudly rather than being silently dropped from /waiting and
  the digest.
- **Resolver hardening:** `WaitingRows.daemon_enabled_resolver` now rescues the
  raw `Psych::Exception`/`SystemCallError` that `Config.load` raises on a
  malformed/unreadable project config (not just `Hive::ConfigError`), so it
  degrades to not-suppressed and memoizes per project instead of re-loading and
  relying on `daemon_plan_pause?`'s backstop.
- **Type-design invariants:** `Result` now enforces `count == tasks.size`, a
  non-zero chat on a real send, `reason "empty"`/`"dry_run"` coherence, an
  Array (not nil) `tasks`, and `Task` a non-null string `title`.
- **Dead code / stale comments:** removed dead `Supervisor#status_action_emoji`
  and `#waiting_row_project_path` delegators (retargeted their test pins at
  `WaitingRows`); corrected the `row_project_path` / reap-pseudo-project /
  ROLE_EMOJI source comments.
- **Simplifications:** extracted `Config.load_global_block`, an
  `AnswerDigest#pr_number` helper, and a frozen `GLOBAL_DIGEST_ACTIONS` map for
  the dispatcher's stage→action lookup.
- **Tests:** added the dispatcher fatal-dedup behavioral test (dedup / re-arm /
  distinct-fault), the scheduler write-failure re-owe test, per-row resilience +
  title-bounding + mid-delivery send fault + stdout-EPIPE tests, the
  end-to-end daemon-enabled plan suppression test, the two-digest single-slot
  contention test, and the full `hive-answer-digest` per-schema suite
  (required-key drift, error-kind routing, success/error round-trips).

**Verification:** focused unit tests for waiting rows, supervisor, answer-digest
command, daemon dispatcher/scheduler, config, and schema files; schema JSON
parse; RuboCop over the touched Ruby and test files.
