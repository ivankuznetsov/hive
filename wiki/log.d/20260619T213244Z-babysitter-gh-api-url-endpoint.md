## [2026-06-19T21:32:44Z] babysitter - skip full-url gh api dry-run endpoints

**Action:** Hardened `bin/hive-babysitter-stub-gh` so `gh api https://...` is treated as a host-carrying endpoint and skipped before the dry-run stub can exec the real `gh`. Added an API endpoint operand parser that skips value-taking API options before checking the endpoint for `://`, so option values such as headers, jq/template strings, and query fields are not mistaken for the endpoint. Relative endpoints such as `repos/owner/repo` still pass when the rest of the `gh api` call is read-only.

**Coverage:** Extended `test/unit/babysitter/dry_run_env_test.rb` with a regression that `gh api https://evil.example.com/repos/owner/repo` is skipped and logged while the existing relative endpoint passthrough stays green. Verified with `bundle exec ruby -Itest test/unit/babysitter/dry_run_env_test.rb`, `ruby -c bin/hive-babysitter-stub-gh`, and `bundle exec rubocop bin/hive-babysitter-stub-gh test/unit/babysitter/dry_run_env_test.rb`.

**Links:** [[modules/babysitter]], [[commands/babysit]], [[testing]]
