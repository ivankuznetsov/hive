---
date: 2026-06-27
slug: babysitter-direct-stub-entrypoints
pages: [modules/babysitter, commands/babysit, testing]
---

`bin/hive-babysitter-stub-git` and `bin/hive-babysitter-stub-gh` are now
shell-only direct-entry guards instead of Ruby scripts. Direct invocation unsets
Ruby/Bundler/Gem startup env (`RUBYOPT`, `RUBYLIB`, `BUNDLE_GEMFILE`,
`BUNDLE_BIN_PATH`, `GEM_HOME`, `GEM_PATH`) and exits 127 without entering Ruby,
so packaged bin files cannot honor caller-controlled Ruby startup hooks before
the dry-run guard.

The dry-run PATH overlay still supports normal babysitter operation: generated
`/bin/sh` launchers scrub the same startup env, pin the parent-resolved real
`git` / `gh` and skip-log handoff values, then invoke private Ruby
implementations under `lib/hive/babysitter/stubs/` through `RbConfig.ruby`.

Regression coverage in `test/unit/babysitter/dry_run_env_test.rb` now checks
direct public-stub refusal with `RUBYOPT=-rpwn` for both allowed reads and
skipped writes, plus the existing overlay startup-env scrub and dry-run
allowlist coverage.
