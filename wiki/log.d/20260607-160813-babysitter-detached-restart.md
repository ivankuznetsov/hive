## [2026-06-07T16:08:13Z] babysitter — fix detached restart process identity

**Action:** Live-smoked a stale babysitter after the current checkout and reproduced that `hive babysit restart --detach` could leave the long-lived process running under the `restart --detach` argv. Later restarts then waited on that process instead of quickly replacing it. Updated `Hive::Commands::Babysit#restart_daemon` so detached restart stops the old process and re-execs the canonical `hive babysit start --detach` command before daemonizing, preserving the PID-file/startup invariant. Kept the long 600-second stop drain because an active babysitter tick can be inside a synchronous PR repair agent; review pass 1 caught that shortening the drain would orphan child agents and temporary worktrees. The same review found that stop could suppress KILL after ownership became unverified yet still delete the PID file and print success, so stop now leaves the PID file and warns when the process may still be alive; KILL escalation is also explicit in stderr. Review pass 2 found that restart could still continue after such a refused stop and that detached re-exec should use the installed stable wrapper rather than raw process argv. Restart now aborts when stop leaves a live PID, direct `stop` exits non-zero in the same refused-stop paths, and detached re-exec resolves the command through `Hive::InvokedBinary.path`. Later review passes found narrow races where a process could exit during initial or post-grace ownership probes; stop now re-checks liveness around those probes and treats a now-dead PID as a clean stale cleanup instead of requiring manual intervention. The final cleanup review found that successful stop cleanup could remove a replacement PID file created by a concurrent `start`; reservation and cleanup now share a sidecar lock and cleanup removes only when the file still matches the payload being stopped, while the detached re-exec call is direct/auditable. Added unit regressions for detached restart re-exec, no-dry-run argv, re-exec failure reporting, unresolved wrapper errors, restart abort after refused stop, direct stop failure on refused stop, ownership-probe clean exits, replacement PID-file preservation, KILL-success cleanup, and skip-KILL PID-file preservation, then refreshed babysitter command/module/testing docs plus the stale-runtime gap.

**Tests:**
- `bundle exec ruby -Itest test/unit/commands/babysit_test.rb`
- `bundle exec ruby -Itest test/unit/babysitter/coverage_gaps_test.rb`
- `bundle exec rubocop lib/hive/commands/babysit.rb test/unit/commands/babysit_test.rb test/unit/babysitter/coverage_gaps_test.rb`

**Refreshed pages:**
- [[commands/babysit]]
- [[modules/babysitter]]
- [[testing]]
- [[gaps]]
