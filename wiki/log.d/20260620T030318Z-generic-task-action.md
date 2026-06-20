## task-action - descriptor-generic status classification

**Action:** Generalized `Hive::TaskAction` for descriptor-resolved non-coding
workflows while keeping the coding workflow on its existing stage-name case.
Added the `ready_to_advance` action kind and current schema enum entries,
emitting `hive approve <slug> --from <descriptor-stage-dir>` for generic
non-terminal `COMPLETE` rows and for a markerless (`:none`) inert entry stage
that is not also terminal. `Hive::Daemon::Policy` now treats
`ready_to_advance` as an advance action so generic COMPLETE rows reach
`:dispatch` at the decision layer. Added descriptor-generic tests plus a
coding action golden matrix.

**Verification:** Focused tests run locally:
`bundle exec ruby -Itest test/unit/task_action_test.rb`,
`bundle exec ruby -Itest test/unit/task_action_generic_test.rb`,
`bundle exec ruby -Itest test/unit/daemon/policy_test.rb`,
`bundle exec ruby -Itest test/unit/exit_codes_test.rb`, and
`bundle exec ruby -Itest test/unit/schema_files_test.rb`.

**Pages:** [[modules/task_action]], [[modules/daemon]], [[testing]]
