# Merge main (daemon tick cadence) into benchmark runtime follow-up

Merged `main` (2 commits, #1189–#1190) into
`fix/opencode-benchmark-runtime-followup` to clear `BEHIND`. Every check on the
branch was already green; `main` sets `required_status_checks.strict`, so being
behind blocks merge on its own — same situation as the previous merge recorded
in [[log]].

The merge was clean and the two sides share **zero** changed files. `main`'s
arrivals are confined to the daemon dispatch loop:

- #1189 adds `patrol_fix_semantic_completion` to `Daemon::Logger`'s allowed
  event list, so the semantic-completion event stops being dropped as unknown.
  Purely additive to a name whitelist.
- #1190 moves `@last_tick_at` assignment out of the top of
  `Dispatcher#tick` into an `ensure`, and derives it from elapsed clock time
  (`full_tick_completion_time`). Full-scan cadence is now spaced from tick
  *completion* rather than tick *start*, so a long scan no longer immediately
  re-arms the next one.

Neither touches this branch's subject matter. Worth stating explicitly because
this branch edits `markers.rb`, and #1189 changes which daemon event names are
accepted — a plausible-looking collision that is not one. The `markers.rb`
change here adds an `at_end:` write mode plus keyword-attr merging to
`Markers.set`; it introduces no daemon event and no `KNOWN_NAMES` entry that
`Daemon::Logger` would have to recognise. See [[modules/markers]] and
[[modules/daemon]].

Local verification after the merge — all green, 0 failures:

- newly arrived: `daemon/dispatcher_test.rb` (288 runs),
  `daemon/logger_test.rb` (9)
- this branch: `opencode_agent_lifecycle_test.rb` (20),
  `stages/execute_test.rb` (45), `stages/base_clean_exit_hook_test.rb` (13),
  `workflows/bench_test.rb` (28), `commands/worktree_test.rb` (25),
  `markers_test.rb` (46), `config_test.rb` (304), `task_action_test.rb` (101),
  `plan_review/transition_guard_test.rb` (8),
  `plan_review/policy_test.rb` (11), `integration/run_execute_test.rb` (14),
  `cli_test.rb` (55)
- component: `opencode_offline_smoke_test.rb`,
  `opencode_preparation_test.rb`, `opencode_result_parser_test.rb`

`bench_test.rb` passed in full this time, including the two
`*_quota_marker_has_canonical_recovery_identity` tests, by putting
`components/agent-cli-runtime/lib` on `RUBYLIB` rather than `-I` — the
previously recorded workaround, confirmed still necessary.

See [[modules/daemon]], [[modules/markers]], [[testing]].
