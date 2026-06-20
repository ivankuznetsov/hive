## [2026-06-20T10:07:48Z] daemon — assign ids to tasks created outside `hive new`

**Action:** Added `Hive::Daemon::TaskIdBackfiller`
(`lib/hive/daemon/task_id_backfiller.rb`), a tick-time self-healer that assigns
a task id to any task whose `meta.yml` has none. `hive new` allocates ids from
`Hive::TaskCounter`, but a task created by hand (`mkdir` + `idea.md`, or one
`mv`-ed into a stage folder) never goes through that path and shows a blank id
in the TUI, `hive status`, the digest, and dependency references.

On each tick the dispatcher now runs the new backfiller right after the
display-name backfiller: for any status row whose `Hive::TaskMeta` `id` is nil
it allocates `TaskCounter.next!`, writes it via the new
`Hive::TaskMeta.update_id` (preserving slug / display_name / depends_on), and
commits the meta on `hive/state` **under the per-project commit lock**
(`Hive::Lock.with_commit_lock`, as every durable `hive_commit` caller does, so
the commit can't interleave with a dispatched child's and cross-contaminate the
audit history or collide on `index.lock`). It is synchronous (id assignment is
instant, so no spawn/inflight tracking), bounded by `max_per_tick` (default 5),
and an assigned id is a natural fixed point — no churn once set. The
`task_id_backfill` event carries `committed:` so a swallowed commit (lock
timeout / git error) is visible rather than masquerading as fully durable.

Critical guard: `id_missing?` returns false unless `File.directory?(folder)`.
A status row can outlive its folder (`hive drop` between snapshot and tick);
since `TaskMeta.write` `mkdir_p`s the path, assigning an id to a vanished folder
would RESURRECT the dropped task (and, because the backfiller runs before
per-row dispatch, defeat the dispatcher's vanished-folder spawn guard). The
existence check skips it. Every per-row step is rescued and `#backfill` never
raises out of the tick. Built at startup and rebuilt on SIGHUP reload alongside
the other backfillers.

Added `test/unit/daemon/task_id_backfiller_test.rb` (assignment, field
preservation, already-has-id skip, dry_run, `max_per_tick`, nil allocation,
vanished-folder no-resurrection, no-raise-on-bad-row) and a `TaskMeta.update_id`
path. Full daemon suite (547 runs) + rubocop green.

**Refreshed pages:**
- [[modules/daemon]]
