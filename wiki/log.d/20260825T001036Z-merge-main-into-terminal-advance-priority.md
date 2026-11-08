# Merge main (bounded liveness, OpenCode limits) into terminal-advance-priority

Merged `main` (7 commits, #1169/#1195/#1198–#1202) into
`fix/patrol-advance-priority` to clear `BEHIND`. Every gating check on the
branch was already green; `main` sets `required_status_checks.strict`, so being
behind blocks merge on its own — same situation as the merges recorded in
[[log]].

The merge was clean. The two sides share exactly **one** changed file,
`wiki/modules/daemon.md`, and it auto-merged: `main` edited the status-fetch
prose while this branch appended a new dispatcher-priority section, so the two
hunks never overlap.

`main`'s arrivals in `lib/hive/daemon/` look like a collision with this branch
and are not one. Worth stating explicitly because this branch rewrites
`Dispatcher`'s priority ordering on top of `Daemon::Policy`:

- `policy.rb`, `concurrency_controller.rb`, `dispatch_baselines.rb` are
  **comment-only** — a docs sweep rewording `hive status --json` to "internal
  task graph". `ADVANCE_ACTIONS` and `Policy.advance?`, which this branch's
  `dispatch_action_rank` / `incremental_dispatch_rows` both key off, are
  byte-identical.
- `status_consumer.rb` (#1195) adds `--internal-task-graph` to the `status`
  argv in `fetch` and `fetch_tasks`. That changes how rows are *fetched*, not
  their shape, so the ordering this branch imposes on them is unaffected.
- `status_report.rb` (#1195) reworks `running_state` with `max_pid_bytes:` and
  `require_start_time:` for bounded liveness. PID-file liveness only; it never
  reaches the dispatch loop.

No commit on `main` touched `lib/hive/daemon/dispatcher.rb` or
`test/unit/daemon/dispatcher_test.rb`.

Local verification after the merge — every file in `test/unit/daemon/` (34
files), all green:

- this branch's subject: `dispatcher_test.rb` (294 runs, 1064 assertions)
- `main`'s arrivals: `status_consumer_test.rb` (29),
  `concurrency_controller_test.rb` (53), `policy_test.rb` (64),
  `dispatch_baselines_test.rb` (25)
- neighbours: `recovery_coordinator_test.rb` (55),
  `refactor_patrol_merge_reconciler_test.rb` (41),
  `dispatch_request_queue_test.rb` (86), `pr_merge_watcher_test.rb` (37), rest

One pre-existing local failure is **not** attributable to the merge:
`child_supervisor_test.rb#test_spawn_tmpdir_log_fallback_loads_its_own_dependency`
fails with `LoadError: cannot load such file -- agent_cli_runtime`. The test
spawns a `ruby -e` subprocess that does not inherit the parent's `-I` flags, so
`components/agent-cli-runtime/lib` drops off the child's load path. It
reproduces identically on a clean `origin/main` checkout with none of this
branch's code, which is what rules out a regression. It is an artifact of
invoking `ruby -I...` directly instead of the `bin/test` wrapper described in
[[testing]]; CI runs under bundler and is green on this file.

See [[modules/daemon]], [[testing]].
