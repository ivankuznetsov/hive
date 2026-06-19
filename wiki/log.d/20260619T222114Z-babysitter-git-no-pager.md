## [2026-06-19T22:21:14Z] babysitter - force no-pager for dry-run git passthrough

**Action:** Hardened `bin/hive-babysitter-stub-git` so allowlisted real-git passthrough always includes `--no-pager` and deletes plain `PAGER` alongside `GIT_PAGER`. Pager env/config remains non-fatal at the skip gate, but allowed reads no longer let TTY stdout trigger a caller- or repo-controlled pager.

**Coverage:** Extended `test/unit/babysitter/dry_run_env_test.rb` with pager env scrubbing assertions and a PTY-backed `git log` regression where `PAGER`, `GIT_PAGER`, and repo-local `core.pager` point at a marker-writing helper. The helper must not run.

**Verified:** `ruby -c bin/hive-babysitter-stub-git`; `env -u GIT_EXEC_PATH -u GIT_EXTERNAL_DIFF -u GIT_SSH_COMMAND -u GIT_SSH -u GIT_ASKPASS -u SSH_ASKPASS -u GIT_PROXY_COMMAND -u GIT_CONFIG_PARAMETERS -u GIT_CONFIG_COUNT -u GIT_CONFIG_GLOBAL -u GIT_CONFIG_SYSTEM bundle exec ruby -Itest test/unit/babysitter/dry_run_env_test.rb`; `bundle exec rubocop bin/hive-babysitter-stub-git test/unit/babysitter/dry_run_env_test.rb`.

**Links:** [[commands/babysit]], [[modules/babysitter]], [[testing]]
