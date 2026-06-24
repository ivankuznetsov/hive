## [2026-06-20T09:49:58Z] babysitter — pin dry-run fixture Ruby shebangs

**Action:** Fixed the CI-only `rake coverage` failures in `test/unit/babysitter/dry_run_env_test.rb` after the git dry-run stub began pinning `PATH=/usr/bin:/bin` before passthrough. The generated fake `git` binaries used `#!/usr/bin/env ruby`, so on GitHub's Ubuntu runner they re-entered system Ruby 3.2.3 and inherited Bundler state for the Ruby 3.4 test process, producing `Bundler::RubyVersionMismatch` before the fixtures could record passthrough. The fixture generators now write `#!#{RbConfig.ruby}` so they keep using the test runner's Ruby even after the production stub pins PATH for helper safety.

**Coverage:** Updated [[testing]] to record that the dry-run fake binaries are pinned to the current test runner Ruby. This is test-harness isolation only; the production stub still pins PATH before execing the configured real git.

**Verification:** `bundle exec ruby -Itest test/unit/babysitter/dry_run_env_test.rb`; `bundle exec rubocop test/unit/babysitter/dry_run_env_test.rb`; `bundle exec rake coverage`.

**Links:** [[testing]], [[modules/babysitter]]
