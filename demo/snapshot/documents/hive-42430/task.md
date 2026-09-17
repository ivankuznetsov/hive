---
slug: improve-hive-web-task-detail-260812-19e1
started_at: 2026-08-12T17:01:00Z
---

# improve-hive-web-task-detail-260812-19e1

## Implementation


## Execute Output

Root cause confirmed:

- The new journal record is valid in the current source: `TaskJournal` explicitly accepts `activity_recorded`, and `TaskProjection` projects it.
- The golden E2E’s daemon spawn environment fails to override an inherited `HIVE_BIN`. On this host that value is `<local-path>`, an older installed build.
- `Commands::Daemon` intentionally preserves explicit `HIVE_BIN`; `StatusConsumer` then invokes that old binary for every `hive status --json`.
- The old status process rejects the new journal event, emits an Error row, and the current daemon correctly refuses to advance it.

The convergent fix is in the E2E harness: pin `HIVE_BIN` to this checkout’s `bin/hive`, just as the test already pins the root bundle and fake agent. The existing golden-path case is the regression test—it currently fails for the exact stale-binary reason. Before editing, I’m validating the independent prediction: overriding only `HIVE_BIN` at launch should make the untouched E2E pass and remove the mixed-version warning.

## Execute Output

Implemented and committed the complete `hive-task-workspace.v1` plan across U1–U9.

- Final HEAD: `4aee99b9af52112c292a72756a05d9a95b0d33d1`
- Final commit: `fix(workspace): preserve activity through agent custody`
- Task commit series: `fe57f4012` through `4aee99b9a` (13 commits)
- Worktree: clean

Delivered bounded provenance, attempts/sessions/resources, audit timeline, dependency component, publication/artifact projections, authenticated JSON parity, accessible responsive Web UI, lifecycle capture fixes, schemas, tests, and wiki documentation. `hive-status.v7` remains unchanged.

Verification:

- Root suite: 12,838 runs, 161,332 assertions, zero failures/errors
- Rails suite: 288 runs, 1,578 assertions, zero failures/errors
- Browser suite: 59 runs, 573 assertions, zero failures/errors
- Schema/status compatibility: 267 runs, 1,514 assertions
- Exact-HEAD focused proof: 63 runs, 296 assertions
- Exact-HEAD golden E2E: 1 run, 14 assertions
- RuboCop: 1,614 root and 125 Web files, no offenses
- Brakeman: zero warnings
- Bundler Audit: no vulnerabilities
- Wiki compilation and diff integrity: clean

Live provider/GitHub calls were intentionally excluded; tests used bounded injected transports. No review pass, push, PR, release, or deployment was performed.

<!-- COMPLETE attempt_id=36ab911a-25f9-4589-ace1-8b9fb27eed13 task_generation=c7cfe147cb5ebfe492e75ac8f84adf305782ad2c7f04c12ba04392d9a9b1aa7b ownership_generation=c7cfe147cb5ebfe492e75ac8f84adf305782ad2c7f04c12ba04392d9a9b1aa7b task_input_epoch=1 -->
