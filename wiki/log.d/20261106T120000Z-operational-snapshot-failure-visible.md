# 2026-11-06 — Operational snapshot failures are logged and surfaced

**Action:** A project had the same task slug in `stages/1-inbox/X` and
`stages/3-generate/X`. Every tick's `OperationalSnapshot::Assembler#complete`
rejected the frame as `duplicate_task_identity`, but `fail` returned silently
because a completed record was retained. Nothing was logged; once the retained
record expired, `hive status --operational` showed only `scheduler_stale:
snapshot_expired`, and quiesce consumers refused with no cause.

- `Assembler#fail` (and a rejecting `#complete`) returns
  `OperationalSnapshot::IncompletePublication(reason, retained, duplicates)`;
  the dispatcher logs it as the new `operational_snapshot_incomplete` event.
- A retained completed record is annotated with `last_failure`
  (`reason`, `since`, `tick_sequence`); phase, tick, and `valid_until` are
  unchanged, the status projection is kept, and the next complete tick clears it.
- `Reader#read` puts the failure into `detail` for `snapshot_expired`;
  `OperationalStatus` appends it to `scheduler_stale` (duplicate-specific
  remediation) or emits a `scheduler_tick_failed` warning while still current.
- The duplicate reason now names project, slug, and every `stage (folder)`.
  Duplicate frames stay fail-closed (no per-task exclusion), because the
  dispatcher still acts on both rows.

**Verification:** focused `daemon/operational_snapshot_test.rb`,
`daemon/dispatcher_test.rb`, `operational_status_test.rb`,
`commands/status_test.rb`, `daemon/logger_test.rb`; RuboCop on changed files.
