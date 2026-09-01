# Patrol validator timeout kills now escalate even when the shell leader exits

**Change:** `Hive::Patrol::Validator#terminate`
(`lib/hive/patrol/validator.rb`) no longer returns early when the
process-group leader survives the `TERM_GRACE_SEC` join. After sending
group TERM and waiting one grace period, it always attempts the group
KILL; `Errno::ESRCH`/`ECHILD` still report that nothing remains.

**Why:** leader liveness was used as a proxy for group liveness. A shell
whose `wait` builtin is interrupted by TERM exits during the grace
period, so the KILL escalation never fired while group members that
trapped TERM (e.g. test-suite children) survived the timeout and kept
running after `validate` returned.

**Tests:** `test/unit/patrol/validator_test.rb` adds
`test_termination_still_escalates_to_kill_when_the_leader_exits_during_grace`
(fake waiter whose join succeeds) and
`test_timeout_kill_reaches_group_members_that_outlive_the_shell` (real
process group where an inner member ignores TERM; asserts it is gone via
`Process.kill(0, pid)` raising `Errno::ESRCH`). Both fail on the previous
implementation.
