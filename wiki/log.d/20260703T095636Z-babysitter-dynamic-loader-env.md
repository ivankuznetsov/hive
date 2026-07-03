## [2026-07-03T09:56:36Z] babysitter - scrub dynamic-loader env in dry-run command stubs

**Action:** Fixed patrol finding `command-bin-hv-1` by adding the dynamic-loader environment family to the babysitter dry-run boundary. The generated PATH overlay launchers now unset `LD_PRELOAD`, `LD_LIBRARY_PATH`, `LD_AUDIT`, `LD_DEBUG_OUTPUT`, `DYLD_INSERT_LIBRARIES`, `DYLD_LIBRARY_PATH`, `DYLD_FRAMEWORK_PATH`, and `DYLD_FALLBACK_LIBRARY_PATH` before handing off to the Ruby stubs; both `git` and `gh` shared stubs scrub the same keys again before any allowlisted real-binary passthrough.

**Coverage:** Extended `test/unit/babysitter/dry_run_env_test.rb` with overlay-handoff and direct-stub passthrough regressions proving those keys are unset before reaching fake real `git` / `gh` binaries.

**Verified:** `bundle exec ruby -Itest test/unit/babysitter/dry_run_env_test.rb`; `bundle exec rubocop bin/hive-babysitter-skip-log.rb bin/hive-babysitter-stub-git bin/hive-babysitter-stub-gh lib/hive/babysitter/dry_run_env.rb test/unit/babysitter/dry_run_env_test.rb`.

**Links:** [[modules/babysitter]], [[commands/babysit]], [[testing]]
