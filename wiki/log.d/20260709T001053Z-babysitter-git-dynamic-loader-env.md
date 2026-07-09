## [2026-07-09T00:10:53Z] babysitter - scrub dynamic-loader env before git dry-run passthrough

**Action:** Fixed patrol finding `command-bin-hive-babysitter-stub-git-3` by removing inherited `LD_*` / `DYLD_*` dynamic-loader environment from `Hive::Babysitter::DryRunEnv.with_env` before generated overlay wrappers can hand off to the Ruby stubs. `bin/hive-babysitter-stub-git` also deletes those names before `exec`ing the real git binary as defense in depth, alongside the existing Git config/helper/pager scrub.

**Coverage:** Extended `test/unit/babysitter/dry_run_env_test.rb` with a Linux `LD_PRELOAD` constructor probe that must not run through the generated dry-run `git` overlay, plus a git passthrough env-recording regression that proves Linux `LD_*` and macOS `DYLD_*` names are absent from the real git process.

**Verified:** `env -u GIT_EXEC_PATH -u GIT_EXTERNAL_DIFF -u GIT_SSH_COMMAND -u GIT_SSH -u GIT_ASKPASS -u SSH_ASKPASS -u GIT_PROXY_COMMAND -u GIT_CONFIG_PARAMETERS -u GIT_CONFIG_COUNT -u GIT_CONFIG_GLOBAL -u GIT_CONFIG_SYSTEM ruby -Itest test/unit/babysitter/dry_run_env_test.rb`

**Links:** [[commands/babysit]], [[modules/babysitter]], [[testing]]
