---
date: 2026-06-14
slug: daemon-mtime-precision
pages: [modules/daemon, testing, gaps]
---

Fixed the hivebox golden-path CI failure where a browser-submitted brainstorm
answer could strand a task at `2-brainstorm` even after the E2E waited for the
daemon's answer window. `hive status --json` publishes `tasks[].mtime` at
whole-second ISO8601 precision, while the daemon records dispatch baselines from
`File.mtime` with subsecond precision. When an answer landed in the same
wall-clock second as the agent's `WAITING` write, the parsed status timestamp
compared older than the fractional post-child baseline and `Policy#decide_edit`
kept returning `:skip`.

`Hive::Daemon::StatusConsumer#parse_mtime` now prefers a local
`File.mtime(state_file)` when the row's `state_file` still exists, falling back
to the JSON timestamp only when the file is unavailable. Added
`test_valid_row_mtime_prefers_state_file_precision` to
`test/unit/daemon/status_consumer_test.rb`, preserving the public status payload
while keeping daemon-internal edit-resume comparisons subsecond-precise.

Refreshed [[modules/daemon]] for the `StatusConsumer` invariant and persisted
baseline section, [[testing]] for `daemon/status_consumer_test.rb` coverage, and
[[gaps]] to keep the broader pre-baseline brainstorm-answer window open while
noting that the same-second precision variant is fixed. Verified with:
`bundle exec ruby -Itest test/unit/daemon/status_consumer_test.rb`,
`bundle exec ruby -Itest test/integration/cli_version_test.rb`, and
`cd web && bundle exec rails test test/e2e/golden_path_e2e.rb`.
