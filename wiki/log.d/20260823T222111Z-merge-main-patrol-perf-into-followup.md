# Merge main (patrol/status perf) into benchmark runtime follow-up

Merged `main` (11 commits, #1175–#1188) into
`fix/opencode-benchmark-runtime-followup` to clear `BEHIND`. Every check on
the branch was already green; `main` sets
`required_status_checks.strict`, so being behind blocks merge on its own.

The merge was clean, and structurally so: the two sides share **zero** changed
files. `main`'s commits are confined to the patrol/daemon/status read path
(`patrol_fix/admission_store.rb`, `daemon/operational_snapshot.rb`,
`task_projection/store.rb`, `commands/status.rb`, `managed_directory.rb`) plus
their tests and wiki pages; this branch touches the opencode agent runtime,
`stages/execute`, `commands/worktree`, and the bench harness.

One arrival is directly relevant here. #1185 makes `bin/hive` prepend
`components/agent-cli-runtime/lib` to `$LOAD_PATH` when that source tree is
present, so a dev checkout now loads the in-repo agent runtime instead of an
installed `agent-cli-runtime` gem at the same version. That removes a
shadowing hazard for this branch specifically, since it edits
`opencode/probe.rb` and `opencode/result_parser.rb` — before #1185 a
`bin/hive` run could silently exercise the packaged copy of those files.

Local verification after the merge: `opencode_agent_lifecycle_test.rb`,
`stages/execute_test.rb`, `commands/worktree_test.rb`, and
`stages/base_clean_exit_hook_test.rb` all pass. `bench_test.rb`'s two
`*_quota_marker_has_canonical_recovery_identity` tests fail without bundler
and pass once `components/agent-cli-runtime/lib` is on `RUBYLIB` rather than
`-I` — the subprocess those tests spawn rebuilds `RUBYLIB` from `lib` plus the
inherited value, so `-I` paths do not propagate. Same environmental failure
already recorded in [[log]] for the CI-velocity merge; not a regression.
`cli_version_test.rb` fails locally for the unrelated reason that `thor` is
not installed outside the bundle.

See [[modules/agent_cli_runtime]], [[modules/workflows]], [[testing]].
