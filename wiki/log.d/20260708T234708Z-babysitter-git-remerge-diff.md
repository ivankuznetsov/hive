## [2026-07-08T23:47:08Z] babysitter - block git remerge-diff dry-run passthrough

**Action:** Fixed patrol finding `command-bin-hive-babysitter-stub-git-2` by hardening `bin/hive-babysitter-stub-git` before it execs an allowlisted `git log` / `git show` read. The stub now skips `--remerge-diff`, `--diff-merges=remerge`, and `--diff-merges=r` because Git replays merge machinery for those formats and can execute repo-local merge drivers. Allowed passthrough also pins `log.diffMerges=separate`, so `-m` / `--diff-merges=on` cannot inherit a repo-local `log.diffMerges=remerge` default.

**Coverage:** Extended `test/unit/babysitter/dry_run_env_test.rb` with a real temporary merge repository whose `merge=pwn` driver writes a marker. The regression proves explicit remerge-diff options are skipped without running the driver, while ordinary `-m` / `--diff-merges=on` passthrough still reaches real git without honoring a configured remerge default. Refreshed [[commands/babysit]], [[modules/babysitter]], [[testing]], and [[gaps]].

**Verified:** `ruby -c bin/hive-babysitter-stub-git`; `ruby -c test/unit/babysitter/dry_run_env_test.rb`; `bundle exec ruby -Itest test/unit/babysitter/dry_run_env_test.rb -n '/remerge/'`; `bundle exec ruby -Itest test/unit/babysitter/dry_run_env_test.rb`; `bundle exec rubocop bin/hive-babysitter-stub-git test/unit/babysitter/dry_run_env_test.rb`.

**Links:** [[commands/babysit]], [[modules/babysitter]], [[testing]], [[gaps]]
