## [2026-06-07T16:08:13Z] babysitter — fix detached restart process identity

**Action:** Live-smoked a stale babysitter after the current checkout and reproduced that `hive babysit restart --detach` could leave the long-lived process running under the `restart --detach` argv. Later restarts then waited on that process instead of quickly replacing it. Updated `Hive::Commands::Babysit#restart_daemon` so detached restart stops the old process and re-execs the canonical `hive babysit start --detach` command before daemonizing, preserving the PID-file/startup invariant. Kept the long 600-second stop drain because an active babysitter tick can be inside a synchronous PR repair agent; review pass 1 caught that shortening the drain would orphan child agents and temporary worktrees. Added unit regressions for detached restart re-exec and re-exec failure reporting, then refreshed babysitter command/module/testing docs plus the stale-runtime gap.

**Tests:**
- `bundle exec ruby -Itest test/unit/commands/babysit_test.rb`
- `bundle exec ruby -Itest test/unit/babysitter/coverage_gaps_test.rb`
- `bundle exec rubocop lib/hive/commands/babysit.rb test/unit/commands/babysit_test.rb`

**Refreshed pages:**
- [[commands/babysit]]
- [[modules/babysitter]]
- [[testing]]
- [[gaps]]
