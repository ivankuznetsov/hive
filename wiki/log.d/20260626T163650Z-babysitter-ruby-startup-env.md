---
date: 2026-06-26
slug: babysitter-ruby-startup-env
pages: [modules/babysitter, commands/babysit, testing]
---

`Hive::Babysitter::DryRunEnv` now generates `/bin/sh` overlay launchers for
dry-run `git` / `gh` instead of Ruby launchers. The shell wrappers unset
Ruby/Bundler/Gem startup injection env (`RUBYOPT`, `RUBYLIB`,
`BUNDLE_GEMFILE`, `BUNDLE_BIN_PATH`, `GEM_HOME`, `GEM_PATH`) before exporting
the pinned `HIVE_BABYSITTER_REAL_*` and skip-log handoff values, then exec the
shared Ruby stubs through the pinned test/runtime Ruby.

Regression coverage in `test/unit/babysitter/dry_run_env_test.rb` invokes both
overlay `git status --short` and overlay `gh repo view owner/repo` with
command-local `RUBYOPT=-rpwn` and `RUBYLIB` pointed at a marker-writing file.
The marker must not be created, proving no Ruby startup code ran before the
dry-run guard.

Verification: `bundle exec ruby -Itest test/unit/babysitter/dry_run_env_test.rb`
and `bundle exec rubocop lib/hive/babysitter/dry_run_env.rb
test/unit/babysitter/dry_run_env_test.rb`.
