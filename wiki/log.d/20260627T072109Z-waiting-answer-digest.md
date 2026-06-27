---
timestamp: 2026-06-27T07:21:09Z
slug: waiting-answer-digest
tags: [bot, telegram, digest, daemon, config]
---

## [2026-06-27T07:21:09Z] bot — add waiting queue and pending-answer digest

**Action:** Implemented the waiting-on-human-input surface without changing the
existing recovery reminder path or the completed-work digest. Added
`Hive::Bot::WaitingRows` as the shared selector/button helper for
`needs_input` rows, added the `/waiting` Telegram command as the filtered
button-bearing companion to `/status`, and added `hive answer-digest` for one
combined Telegram message with per-task inline buttons when tasks are waiting
on operator input.

Added `Hive::Daemon::AnswerDigestScheduler`, the global `answer_digest` config
block (`enabled`, `hour`), and `answer_digest_state.json` once-per-local-day
state. The daemon now dispatches `hive answer-digest --date YYYY-MM-DD --json`
at or after the configured local hour, marks empty successful snapshots as
fired, retries failures with bounded backoff, and keeps digest-like jobs out of
normal task capacity by sharing the existing digest concurrency slot.

Updated [[commands/answer-digest]], [[commands]], [[commands/bot]],
[[modules/daemon]], [[modules/config]], [[testing]], and [[index]] to describe
the new command, scheduler, config, tests, and bot surface. Did not edit
compiled [[log]].

**Verification:** `bundle exec rake test`, `bundle exec rake coverage`,
focused unit tests for waiting rows, bot routing/supervisor/slash handlers,
answer digest, daemon scheduler/dispatcher, daemon command wiring, config, and
CLI help, plus RuboCop over the touched Ruby files.
