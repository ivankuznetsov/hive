## [2026-07-08T17:33:38Z] babysitter - skip git submodule diff passthrough

**Action:** Fixed patrol finding `command-bin-hive-4` by hardening `bin/hive-babysitter-stub-git` against `--submodule=diff` and split `--submodule diff` on allowlisted read commands. The dry-run stub already injects top-level `--no-ext-diff --no-textconv` for `diff` / `log` / `show`; the new guard skips submodule diff expansion because it can enter nested repositories outside that top-level hardening.

**Coverage:** Extended `test/unit/babysitter/dry_run_env_test.rb` so both submodule diff spellings are logged as skipped and do not reach the recording real git.

**Verified:** `bundle exec ruby -Itest test/unit/babysitter/dry_run_env_test.rb`; `ruby -c bin/hive-babysitter-stub-git`; `bundle exec rubocop bin/hive-babysitter-stub-git test/unit/babysitter/dry_run_env_test.rb`.

**Links:** [[modules/babysitter]], [[testing]]
