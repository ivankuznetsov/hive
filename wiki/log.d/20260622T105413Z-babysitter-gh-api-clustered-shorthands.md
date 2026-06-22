---
date: 2026-06-22
slug: babysitter-gh-api-clustered-shorthands
pages: [commands/babysit, modules/babysitter, testing]
---

Hardened `bin/hive-babysitter-stub-gh` so the `gh api` dry-run classifier
parses clustered short options with gh/pflag value semantics. The guard now
treats clustered non-GET methods such as `-iX POST` and clustered implicit
payloads such as `-if body=hi` as unsafe, while still stopping on value-taking
read options like `-H`, `-q`, `-p`, and `-t` so payload-looking characters
inside their values are data.

Added focused regressions in `test/unit/babysitter/dry_run_env_test.rb` and
refreshed [[commands/babysit]], [[modules/babysitter]], and [[testing]].
Verified with:

- `bundle exec ruby -Itest test/unit/babysitter/dry_run_env_test.rb --name test_stubs_skip_unknown_and_mutating_commands_but_allow_read_only_commands`
- `bundle exec ruby -Itest test/unit/babysitter/dry_run_env_test.rb`
- `bundle exec rubocop bin/hive-babysitter-stub-gh test/unit/babysitter/dry_run_env_test.rb`
