## [2026-07-03T17:36:22Z] babysitter - scrub loader env before gh dry-run handoff

**Action:** Hardened `bin/hive-babysitter-stub-gh` after a patrol finding showed the Ruby executable stub and allowlisted passthrough could inherit startup hooks such as `LD_PRELOAD`. Read `.llm-wiki/config.json`, searched QMD and the configured master wiki, then checked [[commands/babysit]], [[testing]], `lib/hive/babysitter/dry_run_env.rb`, `bin/hive-babysitter-stub-gh`, and `test/unit/babysitter/dry_run_env_test.rb`.

**Result:** The installed `gh` stub is now a shell launcher that clears Ruby/Bundler/Gem startup env plus common dynamic-loader env before loading `bin/hive-babysitter-stub-gh.rb`. The dry-run PATH overlay clears the same startup/loader list before invoking Ruby, and the Ruby guard deletes those variables again before execing real `gh`.

**Coverage:** Extended `test/unit/babysitter/dry_run_env_test.rb` so direct `gh` stub execution rejects `RUBYOPT` startup injection and allowlisted `gh` passthrough records loader/Ruby/Bundler startup env as unset. Extended `test/unit/gemspec_test.rb` so the gem includes the new Ruby implementation file.

**Verified:** `bundle exec ruby -Itest test/unit/babysitter/dry_run_env_test.rb`; `bundle exec ruby -Itest test/unit/gemspec_test.rb`; `sh -n bin/hive-babysitter-stub-gh`; `ruby -c bin/hive-babysitter-stub-gh.rb`; `ruby -c lib/hive/babysitter/dry_run_env.rb`; `bundle exec rubocop bin/hive-babysitter-stub-gh.rb lib/hive/babysitter/dry_run_env.rb test/unit/babysitter/dry_run_env_test.rb test/unit/gemspec_test.rb`.

**Links:** [[commands/babysit]], [[testing]]
