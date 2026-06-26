## babysitter - close relative real-binary dry-run handoff

**Action:** Hardened `Hive::Babysitter::DryRunEnv.which` to return absolute realpaths for resolved `git` / `gh` binaries, even when the matching PATH entry is relative. The shared `git` and `gh` dry-run stubs now exit 127 when `HIVE_BABYSITTER_REAL_GIT` or `HIVE_BABYSITTER_REAL_GH` is unset or non-absolute, so a handoff like `bin/git` cannot be re-resolved after the agent cwd changes to the PR worktree.

**Coverage:** Added `test_with_env_canonicalizes_relative_path_real_binaries_before_agent_cwd_changes` with parent/worktree `bin` directories and fake worktree `bin/git` / `bin/gh` executables, plus `test_stubs_refuse_relative_real_binary_paths` for direct shared-stub invocation.

**Verification:** `bundle exec ruby -Itest test/unit/babysitter/dry_run_env_test.rb -n '/relative_real_binary|canonicalizes_relative_path/'`; `bundle exec ruby -Itest test/unit/babysitter/dry_run_env_test.rb`; `bundle exec rubocop bin/hive-babysitter-stub-git bin/hive-babysitter-stub-gh lib/hive/babysitter/dry_run_env.rb test/unit/babysitter/dry_run_env_test.rb`.

**Links:** [[modules/babysitter]], [[commands/babysit]], [[testing]], [[gaps]]
