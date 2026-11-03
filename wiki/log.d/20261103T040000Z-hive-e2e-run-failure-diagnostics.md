## [2026-11-03T04:00:00Z] e2e - scope unexpected run failure diagnostics

Unexpected `bin/hive-e2e run` failures now include the rescued exception's
class and original message in both human output and the unchanged v1 JSON
error envelope. Only `HIVE_E2E_DEBUG=1` adds one stderr block with that
exception's own backtrace; causes are never rendered. Expected errors and
ordinary scenario report rows retain their existing contracts.

Runner still attempts its crashed-status report write, but a secondary write
failure cannot mask the original exception, backtrace, or cause. Unusable run
storage may leave no crashed-status report; no retry or fallback artifact is
introduced. [[e2e]] documents the contract, and [[gaps]] records the unchanged
post-report-emission ordering and lack of a dedicated regression for it.

Verification: the binary suite passed 73 tests / 1,155 assertions; the Runner
suite passed 14 tests / 104 assertions. Regressions cover original exception
identity and both crashed-report outcomes, human/JSON parity, exact debug
activation, expected-error compatibility, repeat behavior, and ordinary
scenario failures. `bundle exec rake e2e:lib_test` passed 228 tests / 1,948
assertions. `bundle exec rake e2e` passed all 21 executable scenarios (24
selected, 3 pending) with artifacts under `/tmp/hive-e2e-verification.kB3tB3`.
Targeted RuboCop passed for all four Ruby files.

The single `bin/test --all` checkpoint completed in 1,546 seconds with four
failures and 23 errors across the Hive workers; the standalone component
completed 139 tests with no failures or errors and two skips. The unchanged
process-custody implementation at
`lib/hive/invocation_process_custody.rb:112` raised `Errno::ESRCH` while reading
`/proc/<pid>/environ`. This affected:

- `InvocationProcessCustodyTest#test_cleanup_terminates_a_reparented_setsid_process_and_spares_another_run`.
- `OpenCodeExecutionIntegrationTest#test_fake_cli_completes_a_skill_dependent_plan_through_native_ce_readiness`.
- `OpenCodeExecutionIntegrationTest#test_fake_cli_completes_execute_with_native_state_policy_and_identity`.
- All 22 `OpenCodeAgentLifecycleTest` cases: 20 errors and two failures where
  the expected `Hive::AgentError` / `Hive::ConfigError` was replaced by
  `Errno::ESRCH` (`test_skill_readiness_is_rechecked_inside_the_native_environment`
  and `test_launch_channels_reject_untyped_arguments_and_tools`). A representative
  ordinary lifecycle error was `test_success_uses_native_state_for_run_and_export`.

A clean, detached snapshot of starting commit `966211001e` reproduced the
first three errors using the exact test names above (one custody test and two
integration tests). The same `Errno::ESRCH` occurred at the same source line,
including `/proc/27018/environ` in those reproductions. A further baseline run
loaded `test/unit/opencode_agent_lifecycle_test.rb`,
`test/integration/wiki_command_index_test.rb`, and
`test/integration/release_candidate_cli_test.rb` together with
`bundle exec ruby -Itest -Ilib -e 'ARGV.each { |path| require File.expand_path(path) }'`.
It completed 38 tests with eight failures and 13 errors, all in the native
OpenCode lifecycle cases, including the same process-read error and timeout
outcomes. No process-custody or OpenCode code was changed for this task.

The other two broad failures observed concurrent verification work:
`ReleaseCandidateCliTest#test_no_verb_defaults_to_read_only_plan_with_committed_input_blocks`
captured `c17d1dbc2a` before the next unit commit and then observed
`9e271cec69`; and
`WikiCommandIndexIntegrationTest#test_public_help_metadata_and_navigation_are_one_read_only_contract`
observed repository writes during its whole-tree snapshot. Both passed on
isolated reruns with a stable checkout (one test / 18 assertions and one test /
37 assertions respectively). The broad checkpoint is recorded as failed,
with these narrower reruns and baseline evidence, rather than claimed green.
