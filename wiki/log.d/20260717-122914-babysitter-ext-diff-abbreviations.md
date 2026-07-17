## [2026-07-17T12:29:14Z] babysitter — reject external-diff option abbreviations

**Action:** Hardened `bin/hive-babysitter-stub-git` so dry-run read passthrough rejects every positive `--ext-diff` prefix from `--ext` through the full spelling. This prevents a caller option accepted by a Git version or parser from appearing after the stub-injected `--no-ext-diff` and re-enabling a repository-configured external diff command.

**Coverage:** Extended `test/unit/babysitter/dry_run_env_test.rb` with wrapper-level coverage for the complete prefix set and a real-Git regression that uses a marker-producing `diff.external` command for every prefix accepted by the installed Git. Git 2.55.0 accepted only the full spelling during local validation, so the wrapper-level assertions keep the compatibility guard pinned independently of the local parser.

**Verified:** `bundle exec ruby -Itest test/unit/babysitter/dry_run_env_test.rb`

**Links:** [[commands/babysit]], [[modules/babysitter]], [[testing]]
