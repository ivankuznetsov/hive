# 2026-11-03 — Recover failed edit resumes

- Added task-local terminal failure attribution to durable attempts and
  supervised command receipts using existing JSON fields. Stable task identity,
  immutable failed source, and refreshable current input remain distinct.
  Missing receipts, lost attempts, foreign bindings, consumed success, and stage
  handled errors do not manufacture a failed-edit retry. Stage-accepted changed
  Brainstorm output survives a trailing nonzero command exit; unchanged bytes
  and operator edits alone do not establish acceptance.
- Added `failed_edit` to the existing recovery coordinator and v5 dispatch
  envelope. WAITING and latest answers survive retry admission. Existing
  backoff, durable deadlines, deterministic parking, safety, and single-owner
  claims apply. Input rebinding retains failure history and eligibility in one
  live request; ordinary edits do not release parking. The failed-edit-only
  remediation is “edits do not release this park; use the current workflow.retry
  action”. Existing variants retain their original remediation.
- Dispatch scan, queue, completion, restart, and time-only deadline paths now
  converge on recovery before edit-baseline suppression. Completed answers plus
  a restored baseline alone no longer authorize replay. Concurrent operator
  edits are preserved, and completeness/debounce/dependencies/capacity are
  checked again before dispatch.
- CLI, TUI, and web share canonical recovery presentation and fresh-token Retry
  controls. Read-only status can retain bound durable evidence beneath stale or
  unavailable scheduler status without admitting recovery. Parking/repair,
  genuine missing input, running, cooldown/queue, and no-evidence scheduler
  disposition retain their documented precedence and actual reason/time.
- Updated [[modules/daemon]], [[stages/brainstorm]], and [[gaps]]. The original
  suspected SQLite trigger remains unconfirmed and independent of recovery.
- Broad verification also reproduced a pre-existing Linux process-custody race:
  opening an exiting process's environment can raise `ESRCH`. Custody now skips
  that vanished row just as it already skipped `ENOENT`, with a deterministic
  regression observed failing before the fix. [[testing]] records that case.

Verification during implementation:

- Focused attempt/stage tests: 108 tests, 566 assertions; coordinator/repository/
  schema tests: 272 tests, 1,817 assertions. All passed.
- `bin/test test/integration/daemon_auto_retry_test.rb
  test/integration/dispatch_request_concurrency_test.rb
  test/unit/daemon/dispatcher_test.rb test/unit/attempts/dispatcher_test.rb
  test/unit/daemon/recovery_coordinator_test.rb
  test/unit/runtime_control_plane/dispatch_repository_test.rb
  test/unit/schema_files_test.rb`: 751 tests, 3,703 assertions, all passed.
- Focused status/action/schema/snapshot/dispatcher/repository/TUI/feed/workspace
  checks: 1,006 tests, 4,691 assertions, all passed. After the descriptor input
  and hold-presentation regressions were fixed, `bin/test
  test/unit/recovery/presentation_test.rb test/unit/operational_status_test.rb
  test/unit/tui/key_map_test.rb test/unit/tui/views/tasks_pane_test.rb
  test/unit/commands/status_test.rb test/unit/tui/bubble_model_test.rb` passed
  760 tests and 3,091 assertions.
- From `web/`, `bundle exec rails test test/models/task_display_test.rb
  test/models/task_test.rb test/integration/status_test.rb
  test/integration/tasks_test.rb`: 146 tests, 1,199 assertions, all passed.
  `bundle exec rails test test/system/edit_resume_recovery_test.rb` used local
  Playwright Chromium and passed one browser smoke with 16 assertions.
- Scoped RuboCop checks passed for all 51 changed core Ruby files and nine
  changed web Ruby files. Wiki checks passed 52 tests and 211 assertions;
  `git diff --check` passed. `bin/test --changed --list` was inspected: shared
  schema changes select the broad offline fallback, with Rails suites separate.
  Local Bundler and Playwright paths were supplied for the commands above.
- `bin/test --all` completed its two-worker checkpoint in 1,429 seconds:
  15,970 tests, 305,756 assertions, three failures, two errors, and 14 skips.
  The source guard caught a new stage literal, now replaced by the existing
  annotated Brainstorm constant. The legacy redispatch fixture now supplies a
  canonical task path, stable ID, and matching runtime state home. Both process
  errors came from the `ESRCH` race repaired above. The read-only help snapshot
  observed another worker's growing log plus Git/Bundler metadata changes;
  `bin/test test/integration/wiki_command_index_test.rb` passed in isolation
  with two tests and 52 assertions. No snapshot assertion was weakened.
- After those fixes, `bin/test
  test/integration/regression_redundant_redispatch_test.rb
  test/unit/stage_literal_guard_test.rb
  test/unit/invocation_process_custody_test.rb
  test/integration/opencode_execution_test.rb
  test/integration/daemon_auto_retry_test.rb
  test/integration/dispatch_request_concurrency_test.rb` passed 48 tests and 256
  assertions. Final `bin/test test/unit/daemon/dispatcher_test.rb
  test/unit/daemon/recovery_coordinator_test.rb
  test/unit/recovery/presentation_test.rb test/unit/schema_files_test.rb` passed
  654 tests and 3,231 assertions. Scoped lint passed for the follow-up files.
  The full broad checkpoint was not repeated; all reported failures/errors had
  passing focused reruns.
