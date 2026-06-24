## [2026-06-19T21:15:58Z] babysitter — block git signature helpers in dry-run stub

**Action:** Hardened `bin/hive-babysitter-stub-git` so dry-run allowlisted reads no longer execute configured GPG helpers through commit-signature display. The stub now skips `git log` / `git show` `--show-signature`, skips `log` / `show` / `rev-list` `--format` or `--pretty` values containing `%G`, and forces `log.showSignature=false` in the hermetic passthrough config before allowed reads reach real git.

**Coverage:** Extended `test/unit/babysitter/dry_run_env_test.rb` with a synthetic signed commit and fake `gpg.program` marker. The tests prove signature argv is skipped before real git runs and that a repo-local `log.showSignature=true` config is neutralized during plain `git log` passthrough.

**Verification:** `env -u GIT_EXEC_PATH bundle exec ruby -Itest test/unit/babysitter/dry_run_env_test.rb -n '/signature/'`; `env -u GIT_EXEC_PATH bundle exec ruby -Itest test/unit/babysitter/dry_run_env_test.rb`; `bundle exec rubocop bin/hive-babysitter-stub-git test/unit/babysitter/dry_run_env_test.rb`.
