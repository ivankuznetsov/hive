---
timestamp: 2026-06-27T12:00:00Z
slug: answer-digest-review-fixes
tags: [bot, telegram, digest, daemon, config, schema]
---

## [2026-06-27T12:00:00Z] bot/daemon — answer-digest review-pass hardening

**Action:** Applied 6-review fix-pass findings for the waiting-queue /
answer-digest feature.

- **Config:** added `answer-digest` to the daemon `child_verb_timeouts`
  default (3600s) so a wedged answer-digest child can't pin the single global
  digest slot and silently disable all future digests.
- **`Hive::Bot::WaitingRows`:** single-sourced `ROLE_EMOJI` and added load-time
  drift guards validating `NEEDS_INPUT_KINDS` / `URGENCY_RANK` / `ROLE_EMOJI`
  against the closed `RowActions::KINDS` / `ROLES`; threaded an optional logger
  so a dropped/raising row logs instead of vanishing; wrapped `button_for` in a
  per-row rescue; made `urgency_rank` an honest `.fetch`.
  `Supervisor#status_action_button` / `#status_action_emoji` now delegate here.
- **`hive answer-digest`:** matched the supervisor's daemon-enabled resolver
  (`Config.find_project` fallback + `ConfigError` logging); hardened the
  `Result` type (closed `REASONS`, derived `sent`, cross-field validation);
  added the published `hive-answer-digest` (v1) JSON schema with
  `schema`/`schema_version`, true `count`, and a `tasks[]` array; mapped a
  status outage to a distinct `status_unavailable` error_kind; emit a JSON
  envelope on a non-`Hive::Error` crash; registered the command in
  `bin/hive` `JSON_USAGE_ERROR_CONTRACTS`; documented the exit-code/JSON
  contract and clarified that `--date` is echoed-only.
- **Daemon dispatcher:** collapsed the four per-stage digest-reap branches into
  one `complete_digest_scheduler_for` helper and deduped the scheduler
  tick/complete `:fatal` logs.
- **Scheduler:** log a malformed `last_fired_date` instead of self-healing in
  the dark.
- **Wiki:** added `WaitingRows` / `/waiting` to [[modules/bot]], fixed the
  [[index]] ordering, corrected the `--date` wording, and added the
  cross-process long-callback button caveat to [[commands/answer-digest]],
  [[commands]], and [[commands/bot]]. Did not edit compiled [[log]].

**Verification:** focused unit tests for waiting rows, supervisor, answer
digest command, daemon dispatcher/scheduler, config, schema files; plus the CLI
usage-error JSON integration test and RuboCop over the touched Ruby files.
