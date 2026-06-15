## [2026-06-15T14:50:47Z] babysitter - block GIT_EXEC_PATH in git dry-run stub

**Action:** Hardened `bin/hive-babysitter-stub-git` so `GIT_EXEC_PATH` is treated like the unsafe `--exec-path` global option: a set value makes the dry-run stub skip even allowlisted reads, and the env var is scrubbed before any real-git passthrough.

**Coverage:** Added a `test/unit/babysitter/dry_run_env_test.rb` regression with a fake `git-remote-https` helper proving `git remote show origin` is skipped when `GIT_EXEC_PATH` points at attacker-controlled helpers. Refreshed [[commands/babysit]], [[modules/babysitter]], [[testing]], and [[gaps]] wording for the env seam.

**Verified:** `bundle exec ruby -Itest test/unit/babysitter/dry_run_env_test.rb`

**Links:** [[modules/babysitter]], [[commands/babysit]], [[testing]], [[gaps]]
